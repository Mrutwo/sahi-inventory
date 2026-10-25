import SwiftUI

/// "היסטוריית שינויים": chronological list of every inventory change.
struct ActivityView: View {
    private enum KindFilter: String, CaseIterable, Identifiable {
        case all
        case additions
        case removals
        case edits

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return String(localized: "הכל")
            case .additions: return String(localized: "הוספות")
            case .removals: return String(localized: "הוצאות")
            case .edits: return String(localized: "עדכונים")
            }
        }

        func matches(_ kind: ActivityEntry.Kind) -> Bool {
            switch self {
            case .all: return true
            case .additions: return kind == .create || kind == .increase || kind == .restore
            case .removals: return kind == .decrease || kind == .archive
            case .edits: return kind == .set || kind == .edit || kind == .unitChange
            }
        }
    }

    @Environment(InventoryStore.self) private var store
    @State private var entries: [ActivityEntry] = []
    @State private var limit = 100
    @State private var isLoading = false
    @State private var error: AppError?
    @State private var kindFilter: KindFilter = .all

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("סוג", selection: $kindFilter) {
                        ForEach(KindFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                if let error, entries.isEmpty {
                    ContentUnavailableView {
                        Label("לא הצלחנו לטעון את ההיסטוריה", systemImage: "icloud.slash")
                    } description: {
                        Text(error.localizedDescription)
                    }
                } else if entries.isEmpty && !isLoading {
                    ContentUnavailableView("אין עדיין שינויים", systemImage: "clock",
                                           description: Text("כל הוספה, הוצאה ועדכון במלאי יופיעו כאן."))
                }

                ForEach(groupedEntries) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            NavigationLink(value: entry.productId) {
                                ActivityRow(entry: entry)
                            }
                        }
                    } header: {
                        Text(dayTitle(group.day))
                    }
                }

                if entries.count >= limit {
                    Button("טעינת שינויים נוספים") {
                        limit += 100
                        Task { await load() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.background.ignoresSafeArea())
            .overlay {
                if isLoading && entries.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle(Text("היסטוריית שינויים"))
            .navigationDestination(for: UUID.self) { productId in
                ProductDetailView(productId: productId)
            }
            .refreshable { await load() }
            .task(id: store.changeToken) {
                await load()
            }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [ActivityEntry]
        var id: Date { day }
    }

    private var groupedEntries: [DayGroup] {
        let calendar = Calendar.current
        let filtered = entries.filter { kindFilter.matches($0.kind) }
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            DayGroup(day: day, entries: groups[day] ?? [])
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "היום") }
        if calendar.isDateInYesterday(day) { return String(localized: "אתמול") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLocale.current))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await store.fetchActivity(limit: limit)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? AppError) ?? AppError.fromGeneric(error)
        }
    }
}
