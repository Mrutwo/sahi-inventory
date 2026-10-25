import SwiftUI

/// Changes made offline that have not reached the server yet.
struct PendingChangesSheet: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            List {
                if !store.pending.waiting.isEmpty {
                    Section {
                        ForEach(store.pending.waiting) { operation in
                            row(operation)
                        }
                        .onDelete { offsets in
                            let waiting = store.pending.waiting
                            offsets.forEach { store.pending.remove(id: waiting[$0].id) }
                        }
                    } header: {
                        Text("ממתינים לשליחה")
                    } footer: {
                        Text("השינויים יישלחו אוטומטית כשיהיה חיבור. שליחה חוזרת לא תכפיל כמויות.")
                    }
                }
                if !store.pending.failed.isEmpty {
                    Section {
                        ForEach(store.pending.failed) { operation in
                            VStack(alignment: .leading, spacing: 4) {
                                row(operation)
                                if let message = operation.failureMessage {
                                    Text(message)
                                        .font(.footnote)
                                        .foregroundStyle(Brand.danger)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let failed = store.pending.failed
                            offsets.forEach { store.pending.remove(id: failed[$0].id) }
                        }
                    } header: {
                        Text("לא נשמרו")
                    } footer: {
                        Text("השרת דחה את השינויים האלה (למשל: אין מספיק במלאי). החליקו כדי להסיר ובצעו אותם מחדש במידת הצורך.")
                    }
                }
                if store.pending.isEmpty {
                    ContentUnavailableView("אין שינויים ממתינים", systemImage: "checkmark.icloud")
                }
            }
            .navigationTitle(Text("שינויים ממתינים"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סיום") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !store.pending.waiting.isEmpty {
                        Button {
                            isSending = true
                            Task {
                                await store.flushPending()
                                isSending = false
                            }
                        } label: {
                            if isSending {
                                ProgressView()
                            } else {
                                Text("שליחה עכשיו")
                            }
                        }
                        .disabled(!store.isOnline || isSending)
                    }
                }
            }
        }
    }

    private func row(_ operation: PendingOperation) -> some View {
        let unit = store.unit(for: operation.unitCode)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.productName.isEmpty ? String(localized: "מוצר") : operation.productName)
                    .font(.headline)
                Text(operation.createdAt.sahiDateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(QuantityFormatter.signed(operation.delta)) \(unit.displayName)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(operation.delta < 0 ? Brand.danger : Brand.green)
        }
        .accessibilityElement(children: .combine)
    }
}
