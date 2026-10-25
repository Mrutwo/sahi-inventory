import SwiftUI

enum InventoryLayout: String, CaseIterable, Identifiable {
    case cards
    case table

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: return String(localized: "כרטיסים")
        case .table: return String(localized: "טבלה")
        }
    }

    var symbol: String {
        switch self {
        case .cards: return "rectangle.grid.1x2"
        case .table: return "tablecells"
        }
    }

    static let storageKey = "inventoryLayout"
}

/// Main screen: the shared inventory every volunteer sees.
struct InventoryView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(InventoryLayout.storageKey) private var layout: InventoryLayout = .cards

    @State private var path = NavigationPath()
    @State private var isAddingProduct = false
    @State private var isShowingFilters = false
    @State private var isShowingPending = false
    @State private var adjusting: AdjustTarget?
    @State private var contentWidth: CGFloat = 390

    var body: some View {
        @Bindable var store = store

        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14, pinnedViews: []) {
                    InventoryHeaderView(totals: store.totals, onAdd: { isAddingProduct = true })
                    statusBanners
                    CategoryFilterBar(
                        categories: store.activeCategories,
                        selected: $store.filter.categoryIds
                    )
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in contentWidth = width }
                    }
                )
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Brand.background.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "סח״י"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $store.filter.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("חיפוש מוצר"))
            .refreshable { await store.refresh() }
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { productId in
                ProductDetailView(productId: productId)
            }
            .sheet(isPresented: $isAddingProduct) {
                AddProductView()
            }
            .sheet(isPresented: $isShowingFilters) {
                FilterSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isShowingPending) {
                PendingChangesSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $adjusting) { target in
                AdjustStockSheet(productId: target.productId, initialMode: target.mode)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let items = store.visibleItems
        if store.items.isEmpty && (store.loadState == .idle || store.loadState == .loading) {
            loadingPlaceholder
        } else if store.items.isEmpty, let error = loadError {
            ContentUnavailableView {
                Label("לא הצלחנו לטעון את המלאי", systemImage: "icloud.slash")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("ניסיון חוזר") { Task { await store.refresh() } }
                    .buttonStyle(.sahiSecondary)
                    .frame(maxWidth: 220)
            }
            .padding(.top, 24)
        } else {
            if store.items.filter(\.isActive).isEmpty {
                emptyInventory
            } else if items.isEmpty {
                noResults
            } else {
                resultsHeader(count: items.count)
                if layout == .table {
                    InventoryTableView(
                        items: items,
                        isWide: contentWidth >= 560 && !dynamicTypeSize.isAccessibilitySize,
                        pendingDelta: store.pending.pendingDelta(for:)
                    )
                } else {
                    ForEach(items) { item in
                        NavigationLink(value: item.id) {
                            ProductCardView(item: item, pendingDelta: store.pending.pendingDelta(for: item))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { quickActions(for: item) }
                    }
                }
            }
        }
    }

    private var loadError: AppError? {
        if case .failed(let error) = store.loadState { return error }
        return nil
    }

    @ViewBuilder
    private var statusBanners: some View {
        if !store.isOnline {
            StatusBanner(
                kind: .offline,
                title: String(localized: "אין חיבור לאינטרנט"),
                message: offlineMessage
            )
        } else if let error = store.refreshError, !store.items.isEmpty {
            StatusBanner(
                kind: .warning,
                title: String(localized: "הנתונים אינם מעודכנים"),
                message: error.localizedDescription,
                actionTitle: "רענון",
                action: { Task { await store.refresh() } }
            )
        }
        if !store.pending.isEmpty {
            let waiting = store.pending.waiting.count
            let failed = store.pending.failed.count
            StatusBanner(
                kind: failed > 0 ? .warning : .info,
                title: failed > 0
                    ? String(localized: "\(failed) שינויים לא נשמרו")
                    : String(localized: "\(waiting) שינויים ממתינים לסנכרון"),
                message: failed > 0
                    ? String(localized: "השרת דחה חלק מהשינויים. הקישו לפרטים.")
                    : String(localized: "הם יישלחו אוטומטית כשהחיבור יחזור."),
                actionTitle: "פרטים",
                action: { isShowingPending = true }
            )
        }
    }

    private var offlineMessage: String {
        if let synced = store.lastSyncedAt {
            return String(localized: "מוצג המלאי מ\(synced.sahiRelativeDescription). הוספות והוצאות יישמרו וישלחו כשהחיבור יחזור.")
        }
        return String(localized: "הוספות והוצאות יישמרו וישלחו כשהחיבור יחזור.")
    }

    private func resultsHeader(count: Int) -> some View {
        HStack {
            Text(store.filter.isFiltering
                 ? String(localized: "\(count) מוצרים נמצאו")
                 : String(localized: "כל המוצרים"))
                .font(.headline)
                .foregroundStyle(Brand.navy)
            Spacer()
            if store.isRealtimeConnected {
                Label("מסונכרן", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.green)
                    .accessibilityLabel(Text("מסונכרן בזמן אמת"))
            }
        }
        .padding(.top, 4)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                ProductCardView(item: .placeholder, pendingDelta: 0)
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel(Text("טוען את המלאי…"))
    }

    private var emptyInventory: some View {
        ContentUnavailableView {
            Label("המלאי עדיין ריק", systemImage: "basket")
        } description: {
            Text("הוסיפו את המוצר הראשון שנאסף — כל המתנדבים יראו אותו מיד.")
        } actions: {
            Button {
                isAddingProduct = true
            } label: {
                Label("הוספת מוצר", systemImage: "plus")
            }
            .buttonStyle(.sahiPrimary)
            .frame(maxWidth: 260)
        }
        .padding(.top, 16)
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label("לא נמצאו מוצרים", systemImage: "magnifyingglass")
        } description: {
            Text("נסו מילת חיפוש אחרת או נקו את המסננים.")
        } actions: {
            Button("ניקוי חיפוש ומסננים") {
                store.filter.reset()
            }
            .buttonStyle(.sahiSecondary)
            .frame(maxWidth: 260)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private func quickActions(for item: InventoryItem) -> some View {
        Button {
            adjusting = AdjustTarget(productId: item.id, mode: .increase)
        } label: {
            Label("הוספה למלאי", systemImage: "plus.circle")
        }
        Button {
            adjusting = AdjustTarget(productId: item.id, mode: .decrease)
        } label: {
            Label("הוצאה מהמלאי", systemImage: "minus.circle")
        }
        .disabled(item.isOutOfStock)
        Button {
            path.append(item.id)
        } label: {
            Label("פרטים והיסטוריה", systemImage: "info.circle")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker(selection: Binding(get: { store.filter.sort }, set: { store.filter.sort = $0 })) {
                    ForEach(InventoryFilter.SortOrder.allCases) { order in
                        Label(order.title, systemImage: order.symbol).tag(order)
                    }
                } label: {
                    Text("מיון")
                }
                Picker(selection: $layout) {
                    ForEach(InventoryLayout.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                } label: {
                    Text("תצוגה")
                }
                Divider()
                Button {
                    isShowingFilters = true
                } label: {
                    Label("סינון מתקדם", systemImage: "line.3.horizontal.decrease.circle")
                }
            } label: {
                Image(systemName: store.filter.activeFilterCount > 0
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("מיון וסינון"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isAddingProduct = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("הוספת מוצר"))
        }
    }
}

struct AdjustTarget: Identifiable {
    let productId: UUID
    let mode: AdjustStockSheet.Mode
    var id: String { "\(productId.uuidString)-\(mode.rawValue)" }
}

extension InventoryItem {
    /// Shape-only item for loading skeletons.
    static let placeholder = InventoryItem(
        id: UUID(), name: "מוצר לדוגמה", nameKey: "", variant: "", categoryId: nil, unitCode: "unit",
        notes: nil, isActive: true, quantity: 10, productVersion: 1, stockVersion: 1,
        createdAt: Date(), updatedAt: Date(), updatedByName: nil
    )
}
