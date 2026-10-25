# סח"י — Shared Food Inventory for Volunteers

An iPhone app (Swift / SwiftUI, Hebrew-first, RTL) for volunteers of **סח"י – סיירת חסד ייחודית**. Every volunteer works with one shared inventory of collected food. It is stored in a Supabase (Postgres) database and synced live to every device.

> **Verification status.** The database schema, security policies and stock logic were run and tested: 34 automated tests against a real Postgres engine, all passing. The iOS app was written on a Windows machine without Xcode. It has **not yet been compiled or run**. The Swift sources passed a full syntax parse, and the Xcode project file was checked for structural consistency. Compilation, the Swift unit tests and the UI checks still need a Mac (see *Remaining setup*).

---

## 1. What's in the box

```
sahi-inventory/
├── Sahi.xcodeproj/            Xcode project (Xcode 16.3+, iOS 17+, iPhone, portrait)
├── project.yml                XcodeGen fallback, only if the project ever needs regenerating
├── Config/
│   ├── Sahi.xcconfig          build settings; includes Secrets.xcconfig if present
│   ├── Secrets.example.xcconfig  template for your Supabase URL + anon key
│   └── Sahi-Info.plist        Info.plist additions (display name, backend keys)
├── Sahi/                      app sources (folder is synced into the target automatically)
│   ├── App/                   entry point, composition root, root & tab navigation
│   ├── Config/                AppConfig (reads backend settings, rejects placeholders)
│   ├── Models/                InventoryItem, MeasurementUnit, ProductCategory, ActivityEntry, profiles, RPC requests
│   ├── Domain/                name normalization, validation, search/filter/sort, totals, errors, Hebrew history text
│   ├── Services/              SupabaseBackend (auth, data, realtime), network monitor, local cache, logging
│   ├── Stores/                InventoryStore (shared inventory + sync + offline queue), SessionStore, toasts
│   ├── ViewModels/            AddProductViewModel, AdjustStockViewModel
│   ├── Views/                 Inventory, AddProduct, ProductDetail, Activity, Settings, Auth, Components, Theme
│   └── Resources/             Assets (app icon, accent color), Localizable.xcstrings, he.lproj
├── SahiTests/                 XCTest unit tests + opt-in live Supabase integration tests
└── supabase/
    ├── migrations/20261025120000_initial_schema.sql   schema, RLS, RPC functions, realtime
    ├── config.toml            for local development with the Supabase CLI
    ├── dev/sample_inventory.sql   example records — DEVELOPMENT ONLY
    └── tests/                 database tests (Node + embedded Postgres) and a live two-session sync check
```

## 2. How it works

**Shared, cloud-first data.** Supabase Postgres is the source of truth. The app keeps a local snapshot only as a cache, so it starts instantly and still shows the last known stock when offline.

**All writes go through server functions.** The app has read-only access to tables. Every change calls a Postgres function (`add_stock`, `adjust_stock`, `set_stock`, `update_product`, `archive_product`, …). Each function validates the input, locks the affected row and appends an audit record in a single transaction.

**Aggregation.** A product's identity is *(normalized name, unit, variant)*. Normalization trims and collapses spaces, lower-cases, strips niqqud and unifies ״/"/׳. So when volunteer A adds "אורז" 10 יחידות and volunteer B adds " אוֹרֶז " 5 יחידות, both land on **one** row: אורז — 15 יחידות. The add form shows *"המוצר כבר קיים במלאי… הכמות תתווסף למלאי הקיים"* before saving.

**Incompatible units are never combined.** "אורז" in ק"ג is a separate product from "אורז" in יחידות, and the form warns about it. A unit can only be changed when the stock is 0, or by exact conversion within the same dimension (ק"ג ↔ גרם). The header totals show items, kilograms and liters separately.

**No lost updates.**
- Add, increase and decrease are relative changes made under a row lock, so concurrent changes all apply.
- "ספירת מלאי" (setting an exact count) and product edits use optimistic version checks. If someone changed the product meanwhile, the save is rejected, the screen refreshes and the volunteer decides again.
- Every write carries a request id, so a retry or double tap is applied exactly once.

**Realtime.** The app subscribes to changes on `inventory`, `products`, `stock_movements`, `categories` and `profiles`. When anything changes (or the connection comes back) it re-fetches, with a short debounce. A reconnect can therefore never leave a device stale.

**Offline.** An offline banner shows how old the data is. Adds, increases and decreases made offline are queued on the device and sent automatically when the connection returns; idempotent, so no double counting. If the server rejects a queued change (for example, not enough stock), it is shown for review. Edits, exact counts and removals need a connection.

**History.** `stock_movements` is append-only, enforced by a trigger even against the database owner. Each record stores product, change, previous and new quantity, unit, reason, server timestamp, user id and a snapshot of the user's name.

**Zero-stock policy.** A product that reaches 0 stays in the inventory with an "אזל מהמלאי" tag and its full history. It is listed after in-stock products, and a filter hides out-of-stock items. Only an admin's explicit "מחיקת מוצר" archives a product. Archiving writes off the remaining stock as a recorded movement and keeps all history; admins can restore the product from Settings → מוצרים שהוסרו.

**Hebrew & RTL.** Hebrew is the development language, and the layout direction and date/number locale come from the app's own language, not the device's. All UI text is extracted into `Localizable.xcstrings`. Units and categories have `name_en` / `name_ru` columns. Adding Russian or English means adding the localization in Xcode, translating the string catalog, and the language is already listed in `AppLocale.supportedLanguages`.

**Brand.** The colors come from sahi-israel.org: primary blue `#00529C`, light blues `#EEF4FA` / `#C8DCF0`, navy `#0D1E3A`, gold accent `#EDC11C`, green `#9CB734`. Every color has a dark-mode variant. The typography uses the rounded system font, since the site's NextExitRound is a licensed font and is not bundled.

## 3. Backend setup (Supabase)

1. **Create a project** at <https://supabase.com> (the free tier is fine to start). Choose a region close to Israel (e.g. Frankfurt).
2. **Apply the schema.** Either:
   - Dashboard → *SQL Editor* → paste `supabase/migrations/20261025120000_initial_schema.sql` → *Run*; or
   - with the CLI: `supabase link --project-ref <ref>` then `supabase db push`.
3. **Authentication** (Dashboard → *Authentication* → *Providers* → *Email*): keep Email enabled.
   - *Confirm email*: either works. **Off** gives the simplest onboarding; access is still gated by the join code. **On** means volunteers click the email link before their first sign-in.
   - Set *Minimum password length* to 8.
4. **Create the first admin.**
   1. Run the app and sign up with the coordinator's email.
   2. In the SQL Editor run:
      ```sql
      select private.bootstrap_admin('coordinator@example.org', 'CHOOSE-A-JOIN-CODE');
      ```
      This makes that account an admin and sets the first join code. The code is stored only as a salted SHA-256 hash.
5. **Realtime** is enabled by the migration, which adds the tables to the `supabase_realtime` publication. To confirm: Dashboard → *Database* → *Publications* → `supabase_realtime`.
6. **Keys.** Dashboard → *Project Settings* → *API*. Copy the **Project URL host** and the **anon (public)** key. **Never** copy the `service_role` key into the app or this repository.

### Local development (optional)
With Docker and the Supabase CLI installed: `supabase start` applies the migration automatically. Use `SUPABASE_SCHEME = http` and `SUPABASE_HOST = 127.0.0.1:54321` with the local anon key that `supabase start` prints. `supabase/dev/sample_inventory.sql` loads the example products, **for development only**.

## 4. Access control

| Role | Can |
|---|---|
| *pending* (just signed up) | sign in, see own profile, enter the join code — **no** inventory access |
| **volunteer** | view the inventory and history, add products, increase / decrease stock, exact counts, edit products |
| **admin** | everything above, plus remove/restore products, approve / promote / deactivate volunteers, rotate the join code |

- Row-level security is enabled on every table. Members can only read, and anonymous users get nothing. Writes are possible only through the functions above, each of which checks the caller's role.
- **Onboarding:** the volunteer downloads the app → signs up (name, email, password) → enters the join code from the coordinator. An admin can also approve a pending account in Settings → ניהול מתנדבים.
- **When a volunteer leaves:** Settings → ניהול מתנדבים → ⋯ → *השבתת גישה*. Access ends **immediately**, because RLS checks the profile on every request. Their history stays readable with their name. To also block sign-in entirely, delete or ban the user in Dashboard → Authentication → Users.
- **Leaked join code:** set a new one in Settings → קוד הצטרפות. People who already joined are unaffected.
- The last active admin cannot be demoted or deactivated.
- Join-code attempts are rate-limited to 5 per 15 minutes per account.

## 5. Run the app in the iOS Simulator

Requirements: a Mac with **Xcode 16.3 or newer** (the supabase-swift package needs Swift 6.1 tools; the app code itself compiles in Swift 5 mode).

1. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and fill in `SUPABASE_HOST` (e.g. `abcd1234.supabase.co`) and `SUPABASE_ANON_KEY`.
2. Open `Sahi.xcodeproj`. Xcode resolves the `supabase-swift` package (2.55.x) on first open.
3. Select the **Sahi** scheme and an iPhone simulator, then press ⌘R.
4. Without Secrets.xcconfig the app opens a "נדרשת הגדרת שרת" screen rather than a fake backend.
5. To run on a physical iPhone, select your team under *Signing & Capabilities* and, if needed, change the bundle id `org.sahi.inventory`.

**Official logo:** the app draws a brand-colored shield placeholder. To use the real logo, add an image set named **`SahiLogo`** to `Sahi/Resources/Assets.xcassets` (PDF or PNG). It then appears automatically in the header, the login screen and Settings. Only do this with the organization's approval.

## 6. Test synchronization between two devices

**With the app:**
1. Create two accounts and make both members (join code or admin approval).
2. Run the app on two simulators: start one, then pick a second device type and run again with ⌘R. A simulator plus a real iPhone also works.
3. On device A add "פסטה" 20 חבילות → device B shows it within about a second, with no refresh.
4. On device B open פסטה → *הוצאה* 5 → device A shows 15.
5. On both devices add "אורז" in יחידות → one row with the summed quantity. Add "אורז" in ק"ג → a separate row.
6. Open *ספירת מלאי* on both devices, save on A, then save on B → B gets the "עודכן בינתיים" message and the newer value, not an overwrite.
7. Turn on airplane mode on B (or disconnect the Mac's network for a simulator), add stock → "ממתין לסנכרון" appears; reconnect → it syncs and A sees it.

**Without a Mac** (checks the live backend from Windows/macOS/Linux):
```bash
cd supabase/tests && npm install
# set SUPABASE_URL, SUPABASE_ANON_KEY, SAHI_A_EMAIL, SAHI_A_PASSWORD, SAHI_B_EMAIL, SAHI_B_PASSWORD
npm run sync-check
```
This signs in two sessions and checks that realtime delivery works, that 20 concurrent adjustments are all applied, that retries are idempotent and that stale counts are rejected. It then resets the test product's stock.

## 7. Tests

| Suite | How to run | Needs | Result here |
|---|---|---|---|
| **Database** — 34 tests: schema, RLS for anon / pending / member / admin / deactivated users, join code & rate limit, aggregation, incompatible units, idempotency, validation, insufficient stock, version conflicts, safe unit conversion, archive/restore, immutable history | `cd supabase/tests && npm install && npm test` | Node 18+ | ✅ **34/34 passed** (PGlite 0.5.11 = Postgres in WASM) |
| **Swift unit tests** — normalization (mirrors the SQL cases), quantity parsing & Hebrew validation messages, search/filter/sort, zero-stock ordering, totals per dimension, confirmation rules, error mapping, timestamp decoding, RPC encoding, InventoryStore (add, increase/decrease, offline queue & reconnect, server rejection, realtime refresh, reconnect catch-up, version conflict, cached data on failure, per-user cache), view models (validation, duplicate-submit prevention, same request id on retry, existing-product detection), SessionStore (pending / join / deactivated / admin / sign-out) | Xcode → ⌘U | Mac + Xcode | ⏳ not run (no Mac available) |
| **Swift integration tests** — two live sessions: aggregation, realtime delivery, 20 concurrent updates, idempotent retry | set `SAHI_TEST_*` env vars in the scheme's Test action, ⌘U | test Supabase project | ⏳ skipped automatically without credentials |
| **Live sync check** | `npm run sync-check` | a configured project | ⏳ needs a project |
| Swift syntax parse of all 55 source files | tree-sitter | — | ✅ clean (only `#Preview`, which the parser's grammar predates) |
| `project.pbxproj` structure (all 33 objects resolve) and JSON/plist validity | script | — | ✅ |

Concurrency note: the embedded Postgres used by the database tests runs on a single connection. It verifies the logic and version checks; true parallel execution is covered by the row locks and by the live checks above.

## 8. Remaining setup (what only you can do)

1. **Supabase project** — create it, apply the migration, run `bootstrap_admin` (section 3).
2. **Mac with Xcode 16.3+** — build, run ⌘U, and fix any compile issues. This code has not been compiled yet, so a few small fixes may be needed on first build.
3. **Visual check on small and large iPhones** — e.g. iPhone SE (3rd gen), iPhone 16 and iPhone 16 Pro Max, with large Dynamic Type sizes and in dark mode. The layouts use flexible SwiftUI stacks and grids with no fixed screen sizes, but they have not been seen on a device yet.
4. **Apple Developer account** — only needed for real iPhones beyond personal testing and for TestFlight / App Store distribution.
5. **Official logo** — add the `SahiLogo` image set once the organization approves (section 5).
6. *(Optional)* Custom SMTP in Supabase (Authentication → SMTP). The built-in email sender is rate-limited and meant for testing, so set this up if email confirmation or password reset will be used at scale.
