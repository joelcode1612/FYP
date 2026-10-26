# UI Mapping Table — new design source → Jaspr web target

Generated before any UI change, for review. **No files were modified to produce this.**

- **Source:** `C:\Users\Lenovo\WorkBuddy AI\new UI design` — 37 HTML pages across 5 modules
- **Target:** `C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web\lib` — 27 page files + 16 shared/infra files, 28 routes

Status key: **MATCH** = clear 1:1 · **SPLIT** = 1 source → 2 target · **MERGED** = 2 source → 1 target · **PENDING** = no counterpart, with reason

---

## 1. sitewise-admin — 6 source pages → 8 target routes

| Source page | Target route | Target file | Status |
|---|---|---|---|
| `index.html` — "Dashboard · Verification overview", `A.init({active:'home'})`, 4 metric cards + 3 queue cards + audit table | `/admin` | `pages/admin/dashboard_page.dart` | **MATCH** |
| `users.html` — "User management" | `/admin/users` | `pages/admin/users_page.dart` | **MATCH** |
| `review.html` — "Property listings"; carries Approve/Reject/Publish/Unpublish, 17 `status` refs | `/admin/verification` **and** `/admin/listings` | `verification_page.dart` + `listings_page.dart` | **SPLIT** — source is one page; target separates the verification queue ("Verification queue", "Awaiting review", "Approve") from listing search ("Listings", "Search listings") |
| `tours.html` — "360° tours" | — | — | **PENDING** — no admin tours route exists |
| `monitoring.html` — "Recommendation records" | — | — | **PENDING** — no admin monitoring route exists |
| `activity.html` — "Statistics & activity" / "What is and is not monitored" | — | — | **PENDING** — no admin activity route exists |
| — | `/admin/user-detail` | `user_detail_page.dart` | **PENDING** — target-only detail page, no source |
| — | `/admin/verification-detail` | `verification_detail_page.dart` | **PENDING** — target-only detail page, no source |
| — | `/admin/listing-detail` | `listing_detail_page.dart` | **PENDING** — target-only detail page, no source |
| — | `/admin/profile` | `profile_page.dart` | **PENDING** — target-only, source admin has no profile page |

**Module score: 3 matched (1 of them a split), 3 source pages unmatched, 4 target-only routes.**

---

## 2. sitewise-entrepreneur — 15 source pages → 10 target routes

| Source page | Target route | Target file | Status |
|---|---|---|---|
| `index.html` — bento dashboard, "Hello, …" | `/entrepreneur` | `pages/entrepreneur/dashboard_page.dart` | **MATCH** |
| `explore.html` — "Commercial properties" | `/entrepreneur/explore` | `explore_page.dart` | **MATCH** |
| `map.html` — "Map & surroundings" (19,274 B, largest entrepreneur page) | `/entrepreneur/explore` | `explore_page.dart` | **MERGED** — target's ExplorePage is "property panel beside the map", i.e. explore + map combined into one route |
| `property.html` — property detail | `/entrepreneur/property-detail` | `property_detail_page.dart` | **MATCH** |
| `compare.html` — "Compare properties" | `/entrepreneur/compare` | `compare_page.dart` | **MATCH** |
| `favourites.html` — "Saved properties" | `/entrepreneur/saved` | `saved_page.dart` | **MATCH** |
| `preferences.html` — "Your preferences" | `/entrepreneur/preferences` | `preferences_page.dart` | **MATCH** |
| `profile.html` — "Profile & preferences" | `/entrepreneur/profile` | `profile_page.dart` | **MATCH** |
| `recommendations.html` — "Your shortlist" | `/entrepreneur/recommendations` | `recommendations_page.dart` | **MATCH** |
| `report.html` — evaluation report | `/entrepreneur/report` | `report_page.dart` | **MATCH** |
| `tour.html` — 360° tour | `/entrepreneur/tour` | `tour_page.dart` | **MATCH** |
| `explanation.html` — recommendation explanation (7,112 B) | — | — | **PENDING** — no `/entrepreneur/explanation` route. May already be folded into `property_detail_page.dart` ("two-column evaluation workspace") — **needs confirmation before mapping** |
| `login.html` — "Log in" | `/login` | `pages/login_page.dart` | **MATCH** |
| `signup.html` — "Create Account" | — | — | **PENDING** — no signup route; target `/login` is a "standalone role picker" only |
| `forgot-password.html` — "Forgot Password" | — | — | **PENDING** — no forgot-password route |

**Module score: 11 matched (1 merged), 3 source pages unmatched.**

---

## 3. sitewise-owner — 7 source pages → 7 target routes

| Source page | Target route | Target file | Status |
|---|---|---|---|
| `index.html` — owner dashboard, "Hello, …" | `/owner` | `pages/owner/dashboard_page.dart` | **MATCH** |
| `properties.html` — "My commercial properties" | `/owner/properties` | `properties_page.dart` | **MATCH** |
| `property-edit.html` — add/edit property (20,836 B) | `/owner/add-property` | `add_property_page.dart` | **MATCH** |
| `property-status.html` — property status | `/owner/property-detail` | `property_detail_page.dart` | **MATCH** |
| `tours.html` — tours list, cue "Start capture" | `/owner/tours` | `tours_page.dart` | **MATCH** |
| `tour-capture.html` — capture workspace (14,105 B), cue "Capture" | — | — | **PENDING** — **the target deliberately has no capture page.** `tours_page.dart` states "Capture runs in the mobile app". The source designs a *web* capture UI the target intentionally does not implement. Confirm whether this is a real gap or a deliberate mobile-only boundary. |
| `profile.html` — "Profile & settings" | `/owner/profile` | `profile_page.dart` | **MATCH** |
| — | `/owner/tour-preview` | `tour_preview_page.dart` | **PENDING** — target-only. Labels are "Tour preview", "Regenerate panorama", "Submit for verification"; no source page carries these. |

**Module score: 6 matched, 1 source page unmatched (deliberate), 1 target-only route.**

---

## 4. sitewise-dashboards — 3 source pages → 0 target routes

| Source page | Target route | Status |
|---|---|---|
| `franchise.html` — "Expansion pipeline" | — | **PENDING** — no franchise route exists |
| `investor.html` — "Underwriting cases" | — | **PENDING** — no investor route exists |
| `leasing.html` — "Portfolio & listing performance" | — | **PENDING** — no leasing route exists |

**Module score: 0 of 3 mappable.** These are three additional role dashboards the target does not implement at all.

---

## 5. sitewise-roles — 6 source pages → 1 target route

| Source page | Target route | Target file | Status |
|---|---|---|---|
| `index.html` — "Find the right place…" (151,622 B — by far the largest file) | `/` and `/landing` | `pages/landing_page.dart` (409 L) + `layouts/marketing_layout.dart` | **MATCH** |
| `owner-operator.html` — "Open your next site with fewer surprises." (33,687 B) | — | — | **PENDING** — no route |
| `franchise-development.html` — "Screen territories at portfolio speed." (32,266 B) | — | — | **PENDING** — no route |
| `investor-analyst.html` — "Underwrite location risk with an auditable trail." (31,930 B) | — | — | **PENDING** — no route |
| `leasing-real-estate.html` — "Lease it faster, with evidence attached." (31,371 B) | — | — | **PENDING** — no route |
| `ai-dss-platform.html` — "Deterministic where it matters." (41,358 B) | — | — | **PENDING** — no route |

**Module score: 1 of 6 mappable.** Note the asymmetry: `roles/index.html` is 151 KB against the target's 409-line `landing_page.dart`, so even the one match is a large source against a much smaller target.

---

## 6. Shared source assets → target shared files

| Source | Target | Status |
|---|---|---|
| `sitewise-roles/theme.css` (`:root` tokens) | `web/styles.css` `:root` | **MATCH** — already applied |
| `sitewise-entrepreneur/assets/css/app.css` (component layer) | `web/styles.css` component rules + `lib/components/ui.dart` | **MATCH** — partially applied |
| `shared/pill-nav.css` + `pill-nav.js` | `.app-pill` rules in `styles.css` + `AppLayout` in `lib/layouts/app_layout.dart` | **PARTIAL** — pill is implemented; the **skip link** (`.pillnav-skip`) and `scroll-padding-top` are not |
| `sitewise-owner/assets/css/owner.css` | `.st` pills → `SitewiseStatusBadge`; `.rows`/`.row-card` | **MATCH** — component equivalents exist |
| `sitewise-admin/assets/css/admin.css` | admin page rules | **PARTIAL** |
| `sitewise-dashboards/assets/dashboard.css` | — | **PENDING** — no dashboards module in target |
| `sitewise-entrepreneur/assets/css/bento.css` | `.dash*` rules | **MATCH** — bento grid ported earlier |
| `sitewise-entrepreneur/assets/css/auth.css` | — | **PENDING** — no signup/forgot-password pages to style |

---

## Totals

| | Count |
|---|---|
| Source pages | 37 |
| Target routes / page files | 28 / 27 |
| **MATCH** | **21** |
| **SPLIT** (1 source → 2 target) | 1 |
| **MERGED** (2 source → 1 target) | 1 |
| **PENDING — source page with no target route** | **12** |
| **PENDING — target route with no source page** | **6** |

The 12 unmatched source pages: `admin/{tours,monitoring,activity}`, `entrepreneur/{explanation,signup,forgot-password}`, `owner/tour-capture`, `dashboards/{franchise,investor,leasing}`, `roles/{owner-operator,franchise-development,investor-analyst,leasing-real-estate,ai-dss-platform}`.

The 6 target-only routes: `admin/{user-detail,verification-detail,listing-detail,profile}`, `owner/tour-preview`.

---

## Open questions requiring your decision

1. **`entrepreneur/explanation.html`** — is the SHAP-style explanation a separate route, or is it already inside `property_detail_page.dart`? This changes whether it is PENDING or MATCH.
2. **`owner/tour-capture.html`** — the target says "Capture runs in the mobile app". Is web capture deliberately out of scope, or a genuine gap?
3. **`sitewise-dashboards` (3 pages)** — franchise / investor / leasing dashboards have no target routes at all. Building them would mean **new pages**, which your brief forbids. Confirm they stay PENDING.
4. **`sitewise-roles` (5 of 6 pages)** — same situation. Only `index.html` maps to `landing_page.dart`.
5. **`admin/review.html` split** — the target already splits it into `/admin/verification` and `/admin/listings`. Which source layout should each half follow?

## Recommendation

Apply the new design only to the **21 MATCH + 1 SPLIT + 1 MERGED = 23 mapped pages**, plus the shared token/component layer. Leave all 18 PENDING items untouched and un-styled, per the "do not invent" constraint. Confirm the five questions above and I will proceed page by page.
