import XCTest
@testable import Sahi

final class ProductNameNormalizerTests: XCTestCase {
    func testKeyMatchesServerNormalization() {
        // Same cases as supabase/tests/db.test.mjs → keeps client and server in sync.
        XCTAssertEqual(ProductNameNormalizer.key("  אורז   בסמטי "), "אורז בסמטי")
        XCTAssertEqual(ProductNameNormalizer.key("אוֹרֶז"), "אורז")
        XCTAssertEqual(ProductNameNormalizer.key("ק״ג"), "ק\"ג")
        XCTAssertEqual(ProductNameNormalizer.key("Pasta  BARILLA"), "pasta barilla")
        XCTAssertEqual(ProductNameNormalizer.key("טונה\tבשמן"), "טונה בשמן")
    }

    func testDisplayNameKeepsCaseButCleansWhitespace() {
        XCTAssertEqual(ProductNameNormalizer.displayName("  Pasta   Barilla \n"), "Pasta Barilla")
        XCTAssertEqual(ProductNameNormalizer.displayName("   "), "")
    }
}

final class QuantityValidationTests: XCTestCase {
    private let units = Fixtures.unitsByCode

    func testParsesDotsAndCommas() {
        XCTAssertEqual(QuantityParser.parse("12")?.value, 12)
        XCTAssertEqual(QuantityParser.parse("2.5")?.value, Decimal(string: "2.5"))
        XCTAssertEqual(QuantityParser.parse("2,5")?.value, Decimal(string: "2.5"))
        XCTAssertEqual(QuantityParser.parse(" 7 ")?.value, 7)
        XCTAssertEqual(QuantityParser.parse("0.125")?.fractionDigits, 3)
    }

    func testRejectsInvalidText() {
        for text in ["", "abc", "1.2.3", "12abc", ".5", "5.", "1e3", "+4", "١٢"] {
            XCTAssertNil(QuantityParser.parse(text), text)
        }
    }

    func testValidationMessages() {
        let unit = units["unit"]
        let kg = units["kg"]
        XCTAssertEqual(failure(ProductValidator.validateQuantity("", unit: unit)), .quantityEmpty)
        XCTAssertEqual(failure(ProductValidator.validateQuantity("abc", unit: unit)), .quantityInvalid)
        XCTAssertEqual(failure(ProductValidator.validateQuantity("0", unit: unit)), .quantityNotPositive)
        XCTAssertEqual(failure(ProductValidator.validateQuantity("-3", unit: unit)), .quantityNegative)
        XCTAssertEqual(failure(ProductValidator.validateQuantity("2000000", unit: unit)), .quantityTooLarge)
        XCTAssertEqual(failure(ProductValidator.validateQuantity("1.5", unit: unit)), .quantityNotWhole(unitName: "יחידות"))
        XCTAssertEqual(failure(ProductValidator.validateQuantity("1.2345", unit: kg)), .quantityTooManyDecimals)
        XCTAssertEqual(try ProductValidator.validateQuantity("1.5", unit: kg).get(), Decimal(string: "1.5"))
        XCTAssertEqual(try ProductValidator.validateQuantity("0", unit: unit, allowZero: true).get(), 0)
    }

    func testNameValidation() {
        XCTAssertEqual(ProductValidator.validateName("   "), .nameEmpty)
        XCTAssertEqual(ProductValidator.validateName(String(repeating: "א", count: 121)), .nameTooLong)
        XCTAssertNil(ProductValidator.validateName("אורז"))
        XCTAssertEqual(ProductValidator.validateNotes(String(repeating: "x", count: 501)), .notesTooLong)
    }

    func testMessagesAreHebrew() {
        XCTAssertEqual(ValidationIssue.nameEmpty.message, "יש להזין שם מוצר")
        XCTAssertEqual(ValidationIssue.unitMissing.message, "יש לבחור יחידת מידה")
    }

    private func failure(_ result: Result<Decimal, ValidationIssue>) -> ValidationIssue? {
        if case .failure(let issue) = result { return issue }
        return nil
    }
}

final class InventoryQueryTests: XCTestCase {
    func testSearchIsHebrewAndNiqqudInsensitive() {
        var filter = InventoryFilter()
        filter.searchText = "אוֹרֶז"
        let result = InventoryQuery.apply(filter, to: Fixtures.sampleInventory)
        XCTAssertEqual(result.map(\.name), ["אורז"])

        filter.searchText = "ט"
        XCTAssertEqual(Set(InventoryQuery.apply(filter, to: Fixtures.sampleInventory).map(\.name)), ["טונה", "פסטה"])
    }

    func testFiltersByCategoryUnitAndRecency() {
        let old = Date().addingTimeInterval(-10 * 24 * 3600)
        let items = Fixtures.sampleInventory + [Fixtures.item("קמח", quantity: 3, unit: "kg", updatedAt: old)]

        var filter = InventoryFilter()
        filter.categoryIds = [Fixtures.cannedId]
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["טונה"])

        filter = InventoryFilter()
        filter.unitCodes = ["kg"]
        XCTAssertEqual(Set(InventoryQuery.apply(filter, to: items).map(\.name)), ["סוכר", "קמח"])

        filter.recentWindow = .week
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["סוכר"])
        XCTAssertEqual(filter.activeFilterCount, 2)
    }

    func testZeroStockStaysListedAfterInStockItems() {
        let items = [Fixtures.item("אורז", quantity: 0), Fixtures.item("חומוס", quantity: 4), Fixtures.item("במבה", quantity: 9)]
        var filter = InventoryFilter()
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["במבה", "חומוס", "אורז"])

        filter.showOutOfStock = false
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["במבה", "חומוס"])
    }

    func testSortOrders() {
        let now = Date()
        let items = [
            Fixtures.item("ב", quantity: 5, updatedAt: now.addingTimeInterval(-60)),
            Fixtures.item("א", quantity: 1, updatedAt: now.addingTimeInterval(-3600)),
            Fixtures.item("ג", quantity: 9, updatedAt: now),
        ]
        var filter = InventoryFilter()
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["א", "ב", "ג"])
        filter.sort = .recentlyUpdated
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["ג", "ב", "א"])
        filter.sort = .quantityDescending
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["ג", "ב", "א"])
        filter.sort = .quantityAscending
        XCTAssertEqual(InventoryQuery.apply(filter, to: items).map(\.name), ["א", "ב", "ג"])
    }

    func testArchivedProductsAreHidden() {
        let items = [Fixtures.item("אורז", quantity: 3, isActive: false), Fixtures.item("שמן", quantity: 1)]
        XCTAssertEqual(InventoryQuery.apply(InventoryFilter(), to: items).map(\.name), ["שמן"])
    }

    func testExistingProductRequiresSameUnit() {
        let items = Fixtures.sampleInventory
        XCTAssertEqual(InventoryQuery.existingProduct(named: " אורז ", unitCode: "unit", in: items)?.name, "אורז")
        // Incompatible unit: never combined with the "יחידות" row.
        XCTAssertNil(InventoryQuery.existingProduct(named: "אורז", unitCode: "kg", in: items))
        XCTAssertEqual(InventoryQuery.sameNameOtherUnits(named: "אורז", unitCode: "kg", in: items).map(\.unitCode), ["unit"])
        XCTAssertNil(InventoryQuery.existingProduct(named: "אורז", unitCode: nil, in: items))
    }

    func testSuggestionsPreferPrefixMatches() {
        let items = [Fixtures.item("שמן זית", quantity: 1), Fixtures.item("רסק עגבניות", quantity: 1), Fixtures.item("עגבניות שימורים", quantity: 1)]
        XCTAssertEqual(InventoryQuery.suggestions(for: "עגב", in: items).map(\.name), ["עגבניות שימורים", "רסק עגבניות"])
        XCTAssertTrue(InventoryQuery.suggestions(for: "  ", in: items).isEmpty)
    }
}

final class InventoryTotalsTests: XCTestCase {
    func testOnlyCompatibleUnitsAreSummed() {
        let items = Fixtures.sampleInventory + [
            Fixtures.item("קמח", quantity: 500, unit: "g"),
            Fixtures.item("ריק", quantity: 0),
            Fixtures.item("בארכיון", quantity: 99, isActive: false),
        ]
        let totals = InventoryTotals.compute(items: items, units: Fixtures.unitsByCode)
        XCTAssertEqual(totals.productCount, 8)
        XCTAssertEqual(totals.outOfStockCount, 1)
        XCTAssertEqual(totals.itemCount, 25 + 18 + 40 + 32) // יחידות + בקבוקים + קופסאות
        XCTAssertEqual(totals.massKg, Decimal(string: "15.5")) // 15 ק"ג + 500 גרם
        XCTAssertEqual(totals.volumeLiters, 12)
    }

    func testUnitConversionRules() {
        let u = Fixtures.unitsByCode
        XCTAssertTrue(u["kg"]!.canConvert(to: u["g"]!))
        XCTAssertFalse(u["box"]!.canConvert(to: u["bottle"]!))
        XCTAssertFalse(u["kg"]!.canConvert(to: u["liter"]!))
        XCTAssertFalse(u["unit"]!.allowsFractions)
        XCTAssertTrue(u["liter"]!.allowsFractions)
    }
}

final class StockChangeGuardTests: XCTestCase {
    func testRequiresConfirmationForSignificantChanges() {
        XCTAssertEqual(StockChangeGuard.confirmationReason(current: 10, new: 0), .emptiesStock)
        XCTAssertEqual(StockChangeGuard.confirmationReason(current: 40, new: 15), .largeDecrease(percent: 63))
        XCTAssertEqual(StockChangeGuard.confirmationReason(current: 10, new: 600), .largeIncrease)
    }

    func testSmallChangesNeedNoConfirmation() {
        XCTAssertNil(StockChangeGuard.confirmationReason(current: 40, new: 35))
        XCTAssertNil(StockChangeGuard.confirmationReason(current: 4, new: 2)) // half, but fewer than 5
        XCTAssertNil(StockChangeGuard.confirmationReason(current: 10, new: 60))
    }
}

final class StockReasonTests: XCTestCase {
    func testEncodeAndDisplay() {
        XCTAssertEqual(StockReason.encode(.distribution, note: ""), "distribution")
        XCTAssertEqual(StockReason.encode(.expired, note: " מדף 3 "), "expired: מדף 3")
        XCTAssertEqual(StockReason.encode(nil, note: "סתם"), "סתם")
        XCTAssertNil(StockReason.encode(nil, note: "  "))
        XCTAssertEqual(StockReason.display("distribution"), "חלוקה למשפחות")
        XCTAssertEqual(StockReason.display("expired: מדף 3"), "פג תוקף: מדף 3")
        XCTAssertEqual(StockReason.display("תרומה מהסופר"), "תרומה מהסופר")
    }
}

final class ActivityDescriberTests: XCTestCase {
    func testHebrewSentences() {
        let increase = entry(kind: .increase, delta: 10, previous: 15, new: 25, unit: "unit", product: "אורז")
        XCTAssertEqual(plain(ActivityDescriber.sentence(for: increase, units: Fixtures.unitsByCode)), "נוספו 10 יחידות אורז")

        let set = entry(kind: .set, delta: 6, previous: 12, new: 18, unit: "bottle", product: "שמן")
        XCTAssertEqual(plain(ActivityDescriber.sentence(for: set, units: Fixtures.unitsByCode)), "הכמות של שמן עודכנה מ-12 ל-18")

        let decrease = entry(kind: .decrease, delta: -5, previous: 32, new: 27, unit: "box", product: "טונה")
        XCTAssertEqual(plain(ActivityDescriber.sentence(for: decrease, units: Fixtures.unitsByCode)), "הוצאו 5 קופסאות טונה")
    }

    /// String(localized:) wraps interpolated values in Unicode direction
    /// isolates (U+2068 ... U+2069) so mixed Hebrew/number text renders
    /// correctly; strip them for comparison.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
    }

    private func entry(kind: ActivityEntry.Kind, delta: Decimal, previous: Decimal, new: Decimal, unit: String, product: String) -> ActivityEntry {
        ActivityEntry(id: 1, productId: UUID(), productName: product, kind: kind, quantityDelta: delta,
                      previousQuantity: previous, newQuantity: new, unitCode: unit, reason: nil, details: nil,
                      createdAt: Date(), createdBy: nil, actorName: "רכזת")
    }
}

final class AppErrorTests: XCTestCase {
    func testServerCodesMapToHebrewErrors() {
        XCTAssertEqual(AppError.fromServerCode("SAHI_INSUFFICIENT_STOCK"), .insufficientStock)
        XCTAssertEqual(AppError.fromServerCode("SAHI_VERSION_CONFLICT"), .versionConflict)
        XCTAssertEqual(AppError.fromServerCode("SAHI_NOT_ADMIN"), .notAdmin)
        XCTAssertEqual(AppError.fromServerCode("SAHI_UNSAFE_UNIT_CHANGE"), .unsafeUnitChange)
        XCTAssertNil(AppError.fromServerCode("something else"))
        XCTAssertEqual(AppError.insufficientStock.localizedDescription, "אין מספיק במלאי לביצוע ההוצאה.")
    }

    func testJoinStatuses() {
        XCTAssertNil(AppError.fromJoinStatus("joined"))
        XCTAssertEqual(AppError.fromJoinStatus("invalid_code"), .invalidJoinCode)
        XCTAssertEqual(AppError.fromJoinStatus("too_many_attempts"), .tooManyAttempts)
        XCTAssertEqual(AppError.fromJoinStatus("account_disabled"), .accountDisabled)
    }

    func testNetworkFailuresAreOffline() {
        XCTAssertEqual(AppError.fromGeneric(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(AppError.fromGeneric(URLError(.timedOut)), .offline)
        XCTAssertTrue(AppError.offline.isConnectivityProblem)
    }
}

final class AppConfigTests: XCTestCase {
    func testRejectsPlaceholdersAndAcceptsRealValues() {
        XCTAssertNil(AppConfig.make(urlString: "https://", key: "abc"))
        XCTAssertNil(AppConfig.make(urlString: "https://YOUR-PROJECT.supabase.co", key: "abc"))
        XCTAssertNil(AppConfig.make(urlString: "https://abc.supabase.co", key: "$(SUPABASE_ANON_KEY)"))
        XCTAssertNil(AppConfig.make(urlString: "https://abc.supabase.co", key: ""))
        XCTAssertEqual(AppConfig.make(urlString: "https://abc.supabase.co", key: "key")?.supabaseURL.host, "abc.supabase.co")
        XCTAssertNotNil(AppConfig.make(urlString: "http://127.0.0.1:54321", key: "key"))
    }
}

final class JSONCodingTests: XCTestCase {
    func testParsesPostgresTimestamps() throws {
        let reference = try XCTUnwrap(JSONCoding.parseTimestamp("2026-10-25T18:20:31+00:00"))
        XCTAssertEqual(JSONCoding.parseTimestamp("2026-10-25T18:20:31.123456+00:00")!.timeIntervalSince(reference), 0.123456, accuracy: 0.000_01)
        XCTAssertEqual(JSONCoding.parseTimestamp("2026-10-25 18:20:31.5+00")!.timeIntervalSince(reference), 0.5, accuracy: 0.000_01)
        XCTAssertEqual(JSONCoding.parseTimestamp("2026-10-25T21:20:31+03:00"), reference)
        XCTAssertEqual(JSONCoding.parseTimestamp("2026-10-25T18:20:31Z"), reference)
        XCTAssertNil(JSONCoding.parseTimestamp("not a date"))
    }

    func testDecodesInventoryRowFromPostgREST() throws {
        let json = """
        [{"id":"6f1f8b5e-2d7a-4c1e-9c3b-0a1b2c3d4e5f","name":"אורז","name_key":"אורז","variant":"",
          "category_id":null,"unit_code":"unit","notes":null,"is_active":true,"quantity":25.000,
          "product_version":1,"stock_version":3,"created_at":"2026-10-25T08:00:00.123456+00:00",
          "updated_at":"2026-10-25T09:30:00+00:00","updated_by_name":"רכזת"}]
        """
        let items = try JSONCoding.decoder.decode([InventoryItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.first?.quantity, 25)
        XCTAssertEqual(items.first?.stockVersion, 3)
        XCTAssertEqual(items.first?.updatedByName, "רכזת")
    }

    func testRequestsEncodeAsRPCParameters() throws {
        let id = UUID()
        let data = try JSONCoding.encoder.encode(UpdateProductRequest(productId: id, expectedVersion: 2, name: "אורז", categoryId: nil, unitCode: "kg", notes: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["p_expected_version"] as? Int, 2)
        XCTAssertTrue(object.keys.contains("p_category_id"), "p_category_id has no SQL default, so null must be sent")
        XCTAssertTrue(object["p_category_id"] is NSNull)

        let add = try JSONCoding.encoder.encode(AddStockRequest(name: "אורז", unitCode: "unit", quantity: 10, categoryId: nil, notes: nil))
        let addObject = try XCTUnwrap(JSONSerialization.jsonObject(with: add) as? [String: Any])
        XCTAssertEqual(addObject["p_quantity"] as? Int, 10)
        XCTAssertNotNil(addObject["p_request_id"])
    }
}
