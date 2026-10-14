# Sitewise FYP — Page Inventory

All screen/page widgets in the workspace, with their route where one exists.
Use this to locate sample UI.

- **Flutter mobile app:** `fyp_mobile_app/lib/presentation/mobile/` — **33 pages**
- **Jaspr web app:** `fyp_jaspr_web/lib/pages/` — **27 pages**
- **Workspace root:** `C:\Users\Lenovo\AndroidStudioProjects\FYP`

The two apps mirror each other almost one-to-one, so any screen has a Flutter
version and a Jaspr version — useful for comparing how the same UI is expressed
in both frameworks.

---

# 1. Flutter mobile app — 33 pages

## Onboarding (6) · route `/onboarding`

| # | Class | File |
|---|---|---|
| 1 | `OnboardingFlowPage` | `onboarding/pages/onboarding_flow_page.dart` |
| 2 | `OnboardingIntroPage` | `onboarding/pages/onboarding_intro_page.dart` |
| 3 | `OnboardingBusinessPreferencesPage` | `onboarding/pages/onboarding_business_preferences_page.dart` |
| 4 | `OnboardingLocationIntelligencePage` | `onboarding/pages/onboarding_location_intelligence_page.dart` |
| 5 | `Onboarding360TourPage` | `onboarding/pages/onboarding_360_tour_page.dart` |
| 6 | `OnboardingGetStartedPage` | `onboarding/pages/onboarding_get_started_page.dart` |

`OnboardingFlowPage` is the host — it owns the `PageView`; the other five are the
individual steps.

## Entry (2)

| # | Class | Route | File |
|---|---|---|---|
| 7 | `MobileAuthPage` | `/auth` | `auth/pages/mobile_auth_page.dart` |
| 8 | `LandingMobilePage` | `/landing` | `landing/pages/landing_mobile_page.dart` |

## F&B Entrepreneur (10) · `/entrepreneur/*`

| # | Class | Route | File |
|---|---|---|---|
| 9 | `EntrepreneurDashboardMobilePage` | `/entrepreneur` | `entrepreneur/pages/entrepreneur_dashboard_mobile_page.dart` |
| 10 | `EntrepreneurExploreMobilePage` | `/entrepreneur/explore` | `entrepreneur/pages/entrepreneur_explore_mobile_page.dart` |
| 11 | `EntrepreneurRecommendationsMobilePage` | `/entrepreneur/recommendations` | `entrepreneur/pages/entrepreneur_recommendations_mobile_page.dart` |
| 12 | `EntrepreneurCompareMobilePage` | `/entrepreneur/compare` | `entrepreneur/pages/entrepreneur_compare_mobile_page.dart` |
| 13 | `EntrepreneurSavedMobilePage` | `/entrepreneur/saved` | `entrepreneur/pages/entrepreneur_saved_mobile_page.dart` |
| 14 | `EntrepreneurPreferencesMobilePage` | `/entrepreneur/preferences` | `entrepreneur/pages/entrepreneur_preferences_mobile_page.dart` |
| 15 | `EntrepreneurPropertyDetailMobilePage` | `/entrepreneur/property-detail` | `entrepreneur/pages/entrepreneur_property_detail_mobile_page.dart` |
| 16 | `EntrepreneurReportMobilePage` | `/entrepreneur/report` | `entrepreneur/pages/entrepreneur_report_mobile_page.dart` |
| 17 | `EntrepreneurTourMobilePage` | `/entrepreneur/tour` | `entrepreneur/pages/entrepreneur_tour_mobile_page.dart` |
| 18 | `EntrepreneurProfileMobilePage` | `/entrepreneur/profile` | `entrepreneur/pages/entrepreneur_profile_mobile_page.dart` |

## Commercial Property Owner (7) · `/owner/*`

| # | Class | Route | File |
|---|---|---|---|
| 19 | `OwnerDashboardMobilePage` | `/owner` | `property_owner/pages/owner_dashboard_mobile_page.dart` |
| 20 | `OwnerPropertiesMobilePage` | `/owner/properties` | `property_owner/pages/owner_properties_mobile_page.dart` |
| 21 | `OwnerAddPropertyMobilePage` | `/owner/add-property` | `property_owner/pages/owner_add_property_mobile_page.dart` |
| 22 | `OwnerToursMobilePage` | `/owner/tours` | `property_owner/pages/owner_tours_mobile_page.dart` |
| 23 | `OwnerPropertyDetailMobilePage` | `/owner/property-detail` | `property_owner/pages/owner_property_detail_mobile_page.dart` |
| 24 | `TourPreviewMobilePage` | `/owner/tour-preview` | `property_owner/pages/tour_preview_mobile_page.dart` |
| 25 | `OwnerProfileMobilePage` | `/owner/profile` | `property_owner/pages/owner_profile_mobile_page.dart` |

> `/owner/capture` is registered as a route but has no page under `pages/` — the
> AR capture screen lives under `lib/presentation/shared/capture/`.

## Administrator (8) · `/admin/*`

| # | Class | Route | File |
|---|---|---|---|
| 26 | `AdminDashboardMobilePage` | `/admin` | `admin/pages/admin_dashboard_mobile_page.dart` |
| 27 | `AdminUsersMobilePage` | `/admin/users` | `admin/pages/admin_users_mobile_page.dart` |
| 28 | `AdminUserDetailMobilePage` | `/admin/user-detail` | `admin/pages/admin_user_detail_mobile_page.dart` |
| 29 | `AdminVerificationMobilePage` | `/admin/verification` | `admin/pages/admin_verification_mobile_page.dart` |
| 30 | `AdminVerificationDetailMobilePage` | `/admin/verification-detail` | `admin/pages/admin_verification_detail_mobile_page.dart` |
| 31 | `AdminListingsMobilePage` | `/admin/listings` | `admin/pages/admin_listings_mobile_page.dart` |
| 32 | `AdminListingDetailMobilePage` | `/admin/listing-detail` | `admin/pages/admin_listing_detail_mobile_page.dart` |
| 33 | `AdminProfileMobilePage` | `/admin/profile` | `admin/pages/admin_profile_mobile_page.dart` |

---

# 2. Jaspr web app — 27 pages

## Public (2)

| # | Class | Route | File |
|---|---|---|---|
| 1 | `LandingPage` | `/` | `pages/landing_page.dart` |
| 2 | `LoginPage` | `/login` | `pages/login_page.dart` |

## F&B Entrepreneur (10) · `/entrepreneur/*`

| # | Class | Route | File |
|---|---|---|---|
| 3 | `DashboardPage` | `/entrepreneur` | `pages/entrepreneur/dashboard_page.dart` |
| 4 | `ExplorePage` | `/entrepreneur/explore` | `pages/entrepreneur/explore_page.dart` |
| 5 | `RecommendationsPage` | `/entrepreneur/recommendations` | `pages/entrepreneur/recommendations_page.dart` |
| 6 | `ComparePage` | `/entrepreneur/compare` | `pages/entrepreneur/compare_page.dart` |
| 7 | `SavedPage` | `/entrepreneur/saved` | `pages/entrepreneur/saved_page.dart` |
| 8 | `PreferencesPage` | `/entrepreneur/preferences` | `pages/entrepreneur/preferences_page.dart` |
| 9 | `PropertyDetailPage` | `/entrepreneur/property-detail` | `pages/entrepreneur/property_detail_page.dart` |
| 10 | `ReportPage` | `/entrepreneur/report` | `pages/entrepreneur/report_page.dart` |
| 11 | `TourPage` | `/entrepreneur/tour` | `pages/entrepreneur/tour_page.dart` |
| 12 | `ProfilePage` | `/entrepreneur/profile` | `pages/entrepreneur/profile_page.dart` |

## Commercial Property Owner (7) · `/owner/*`

| # | Class | Route | File |
|---|---|---|---|
| 13 | `DashboardPage` | `/owner` | `pages/owner/dashboard_page.dart` |
| 14 | `PropertiesPage` | `/owner/properties` | `pages/owner/properties_page.dart` |
| 15 | `AddPropertyPage` | `/owner/add-property` | `pages/owner/add_property_page.dart` |
| 16 | `ToursPage` | `/owner/tours` | `pages/owner/tours_page.dart` |
| 17 | `PropertyDetailPage` | `/owner/property-detail` | `pages/owner/property_detail_page.dart` |
| 18 | `TourPreviewPage` | `/owner/tour-preview` | `pages/owner/tour_preview_page.dart` |
| 19 | `ProfilePage` | `/owner/profile` | `pages/owner/profile_page.dart` |

> `DashboardPage`, `PropertyDetailPage` and `ProfilePage` appear once per role —
> the class name repeats, but each is a separate file under its role folder.

## Administrator (8) · `/admin/*`

| # | Class | Route | File |
|---|---|---|---|
| 20 | `DashboardPage` | `/admin` | `pages/admin/dashboard_page.dart` |
| 21 | `UsersPage` | `/admin/users` | `pages/admin/users_page.dart` |
| 22 | `UserDetailPage` | `/admin/user-detail` | `pages/admin/user_detail_page.dart` |
| 23 | `VerificationPage` | `/admin/verification` | `pages/admin/verification_page.dart` |
| 24 | `VerificationDetailPage` | `/admin/verification-detail` | `pages/admin/verification_detail_page.dart` |
| 25 | `ListingsPage` | `/admin/listings` | `pages/admin/listings_page.dart` |
| 26 | `ListingDetailPage` | `/admin/listing-detail` | `pages/admin/listing_detail_page.dart` |
| 27 | `ProfilePage` | `/admin/profile` | `pages/admin/profile_page.dart` |

---

# 3. Shared UI worth reading for patterns

These are not pages, but they are where the reusable UI lives — usually a better
starting point than a page when you want a component to copy.

## Jaspr web (`fyp_jaspr_web/lib/`)

| File | Contains |
|---|---|
| `components/ui.dart` | `Brand`, `Pill`, `Eyebrow`, `SectionHead`, `ActionLink`, `ActionButton`, `StatCard`, `StepCard`, `FeatureRow`, `WeightBar`, `Icon` |
| `components/property_card.dart` | Property card component |
| `components/bloc.dart` | Cubit → component bridge |
| `components/topbar_controls.dart` | Top bar controls |
| `layouts/app_layout.dart` | Sidebar + topbar shell for the authenticated app |
| `layouts/marketing_layout.dart` | Masthead + footer for public pages |
| `web/styles.css` | **The whole design system** — tokens, components, responsive rules |
| `data/navigation.dart` | Sidebar destinations per role |
| `data/site_content.dart` | Landing copy and content data |

## Flutter mobile (`fyp_mobile_app/lib/presentation/shared/`)

| Folder | Contains |
|---|---|
| `widgets/` | Reusable mobile widgets |
| `capture/` | AR capture / 360° panorama flow (platform-specific) |
| `landing/` | Shared landing content |
| `viewmodels/` | The `ChangeNotifier` view models (being migrated to shared cubits) |

## Shared package (`shared_logic/lib/`)

Framework-free — usable from both apps.

| Path | Contains |
|---|---|
| `src/domain/entities/` | `CommercialProperty`, `LocationAnalysis`, `PropertyRecommendation`, `VirtualTour`, `SitewiseUser`, `AppRole`, … |
| `src/domain/repositories/` | Repository contracts |
| `src/domain/usecases/` | `GetProperties`, `GetRecommendations`, `GetLocationAnalysis`, … |
| `src/application/cubits/` | `AppCubit`, `EntrepreneurCubit` |
| `src/application/states/` | Immutable state classes |
| `src/application/usecases/` | `FilterProperties` |

---

# 4. Quick counts

| Group | Pages |
|---|---|
| Mobile — onboarding | 6 |
| Mobile — entry (auth + landing) | 2 |
| Mobile — entrepreneur | 10 |
| Mobile — owner | 7 |
| Mobile — admin | 8 |
| **Mobile total** | **33** |
| Web — public | 2 |
| Web — entrepreneur | 10 |
| Web — owner | 7 |
| Web — admin | 8 |
| **Web total** | **27** |
| **Grand total** | **60** |
