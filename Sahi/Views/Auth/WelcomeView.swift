import SwiftUI

/// Sign in / sign up. Kept to the minimum: email, password and (for new
/// volunteers) a display name. Access to the inventory is granted afterwards
/// with the organization's join code.
struct WelcomeView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case signIn
        case signUp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .signIn: return String(localized: "כניסה")
            case .signUp: return String(localized: "הרשמה")
            }
        }
    }

    private enum Field: Hashable {
        case name
        case email
        case password
    }

    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network

    @State private var mode: Mode = .signIn
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: AppError?
    @State private var info: String?
    @State private var showValidation = false
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    SahiLogoView(size: 120)
                        .padding(.top, 24)
                    Text(verbatim: "סח״י")
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(Brand.blue)
                    Text("מלאי משותף למתנדבים")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Brand.navy)
                    Text("„הדבר הכי גדול בעולם זה לעשות טוב למישהו אחר“")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    Picker("מצב", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in
                        error = nil
                        info = nil
                        showValidation = false
                    }

                    if mode == .signUp {
                        field(title: "שם מלא", text: $displayName, field: .name, issue: nameIssue) {
                            TextField("איך יופיע השם שלך בהיסטוריה", text: $displayName)
                                .textContentType(.name)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .email }
                        }
                    }

                    field(title: "אימייל", text: $email, field: .email, issue: emailIssue) {
                        TextField("name@example.com", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                            .environment(\.layoutDirection, .leftToRight)
                    }

                    field(title: "סיסמה", text: $password, field: .password, issue: passwordIssue) {
                        SecureField(mode == .signUp ? "לפחות 8 תווים" : "הסיסמה שלך", text: $password)
                            .textContentType(mode == .signUp ? .newPassword : .password)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }

                    if let error {
                        StatusBanner(kind: .warning, title: error.localizedDescription)
                    }
                    if let info {
                        StatusBanner(kind: .info, title: info)
                    }
                    if !network.isOnline {
                        StatusBanner(kind: .offline, title: String(localized: "אין חיבור לאינטרנט"),
                                     message: String(localized: "נדרש חיבור כדי להתחבר."))
                    }

                    Button(action: submit) {
                        ProgressLabel(title: mode == .signIn ? "כניסה" : "הרשמה", isLoading: isWorking)
                    }
                    .buttonStyle(.sahiPrimary)
                    .disabled(isWorking || !network.isOnline)

                    if mode == .signIn {
                        Button("שכחתי סיסמה") { resetPassword() }
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .disabled(isWorking)
                    }
                }
                .cardStyle(padding: 20)

                Text("אחרי ההרשמה תתבקשו להזין קוד הצטרפות שמקבלים מרכז/ת המתנדבים.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.background.ignoresSafeArea())
    }

    // MARK: - Validation

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameIssue: String? {
        guard showValidation, mode == .signUp else { return nil }
        return ProductNameNormalizer.displayName(displayName).isEmpty ? String(localized: "יש להזין שם") : nil
    }

    private var emailIssue: String? {
        guard showValidation else { return nil }
        let parts = trimmedEmail.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") ? nil : String(localized: "כתובת האימייל לא תקינה")
    }

    private var passwordIssue: String? {
        guard showValidation else { return nil }
        if password.isEmpty { return String(localized: "יש להזין סיסמה") }
        if mode == .signUp && password.count < 8 { return String(localized: "הסיסמה צריכה לכלול לפחות 8 תווים") }
        return nil
    }

    // MARK: - Actions

    private func submit() {
        showValidation = true
        error = nil
        info = nil
        guard !isWorking, nameIssue == nil, emailIssue == nil, passwordIssue == nil else { return }
        focusedField = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch mode {
                case .signIn:
                    try await session.signIn(email: trimmedEmail, password: password)
                case .signUp:
                    let outcome = try await session.signUp(email: trimmedEmail, password: password, displayName: displayName)
                    if outcome == .confirmationRequired {
                        info = String(localized: "שלחנו אליכם מייל לאישור הכתובת. אחרי האישור חזרו לכאן והתחברו.")
                        mode = .signIn
                    }
                }
            } catch {
                self.error = (error as? AppError) ?? AppError.fromGeneric(error)
            }
        }
    }

    private func resetPassword() {
        showValidation = false
        let parts = trimmedEmail.split(separator: "@")
        guard parts.count == 2 else {
            error = nil
            info = String(localized: "הזינו את כתובת האימייל ואז הקישו שוב על \"שכחתי סיסמה\".")
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.sendPasswordReset(email: trimmedEmail)
                info = String(localized: "אם הכתובת רשומה, נשלח אליה קישור לאיפוס סיסמה.")
            } catch {
                self.error = (error as? AppError) ?? AppError.fromGeneric(error)
            }
        }
    }

    private func field<Content: View>(
        title: LocalizedStringKey,
        text: Binding<String>,
        field: Field,
        issue: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .focused($focusedField, equals: field)
                .padding(14)
                .frame(minHeight: 50)
                .background(Brand.blueSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(issue == nil ? Color.clear : Brand.danger, lineWidth: 1)
                )
            FieldError(message: issue)
        }
    }
}
