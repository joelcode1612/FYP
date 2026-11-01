# Sitewise master architecture — source and workflow ledger

Snapshot: 1 November 2026. Exactly three primary role lanes; 34 independent tracks and 153 module-labelled blocks. The diagram combines documented requirements with their current implementation status. It is not a certification of production readiness.

Primary specification: `C:/Users/Lenovo/OneDrive/Desktop/RSW_JOELTANHOUJUN_Project1.pdf`, §§1.6, 3.2.1 and 4.4.1–4.4.9. Read directly with PyMuPDF. Current source takes precedence over the older implementation audit. No payments, bookings, notification service or production cloud deployment was inferred.

Code sources: `fyp_jaspr_web/lib/app.dart`, `lib/data/app_locator.dart`, `lib/data/api_property_repository.dart`, `tool/auth_client.js`; `fyp_mobile_app/lib/core/routing/app_routes.dart`, `lib/application/services/service_locator.dart`, `lib/presentation/mobile/start/app_start_gate.dart`, `lib/data/repositories/auth_repository_impl.dart`; shared `AppCubit`, `OwnerCubit`, `AdminCubit`, `TourService`, `VerificationRepositoryImpl`, `TourRepositoryImpl`; mobile panorama generation and OpenCV stitcher; `test/app-api.js`, `test/app-schema.sql`, workbook import tools; `backend/src/sitesense/main.py` and `api/v1/router.py`.

## Interpreting the diagram

- Each role contains parallel tracks. Reading down through tracks is not a required user journey. Account edits, reset requests and logout are independent actions.
- Diamonds show explicit conditions or human approval choices. True continues right; False points to the written alternative below the gate. For approval gates, the True and False result blocks are alternative outcomes, not sequential updates.
- SPEC tracks retain the documented operations without claiming deployment. The named business-assessment modules have no invented ordering or app routes.
- Dashed cross-lane buses L1/L2/T1/T2 are same-process repository dependencies, not network APIs or cross-device events. The exact service method names are shown in the diagram event ledger.
- Web catalogue API access is authenticated. Role checks govern web routing; no claim is made that catalogue reads are restricted by role or that persistent administrative writes exist.
- Web reports currently depend on unavailable analysis; the report UI may remain in its loading state. No successful report export is claimed.
- The separate FastAPI source and research API are shown as unconnected from the current app locators. Their existence does not prove deployed runtime availability.

## Full workflow ledger

### F&B ENTREPRENEUR

#### E01 — Web identity and role access

**Status:** CONNECTED. **References:** REQ-101,102,105.

1. **Sign in with Google or email** — Module: `WebAuth / Supabase SDK`. PKCE callback: /auth/callback
2. **Valid access token?** — Module: `Express authentication middleware`. False: HTTP 401; service outage: 503
3. **Load or create role profile** — Module: `POST /api/me`. UUID, email, name; existing role preserved
4. **URL role matches profile?** — Module: `Jaspr Router redirect`. False: redirect to assigned role home
5. **Open entrepreneur workspace** — Module: `SitewiseApp / AppLayout`. True: role route is displayed

Signup allows entrepreneur or owner; metadata cannot grant administrator.

#### E02 — Mobile startup and authentication

**Status:** LOCAL / DEMO. **References:** REQ-101,102,105.

1. **Onboarding completed?** — Module: `AppStartGate`. False: /onboarding; persist completion
2. **Local session exists?** — Module: `AuthRepositoryImpl.currentUser`. False: /auth; local/demo sign-in
3. **Resolve local user role** — Module: `AppCubit.setRole`. Demo role menu can switch roles
4. **Navigate to role home** — Module: `AppRoutes`. Named routes; no production role API

Email password length is checked; demo account matching is not real password authentication. Provider login is simulated.

#### E03 — Account maintenance and logout

**Status:** MIXED. **References:** REQ-103,104,106.

1. **Open profile / edit fields** — Module: `ProfilePage / mobile profile`. Profile edits are prototype UI state
2. **Request password reset** — Module: `ForgotPasswordPage`. Web validates email; sends no reset email
3. **Sign out of web** — Module: `WebAuth.signout`. Supabase signOut; /login
4. **Sign out of mobile** — Module: `AuthService / local repository`. Delete session.json; /auth

These are independent account actions, not mandatory sequential tasks.

#### E04 — Catalogue search, filters and detail

**Status:** CONNECTED WEB. **References:** REQ-204,205,206; UC105.

1. **Open dashboard / explore** — Module: `EntrepreneurCubit / PropertyService`. Web: imported catalogue; mobile: demo
2. **Fetch catalogue pages** — Module: `ApiPropertyRepository`. GET /api/catalog/properties; limit 200
3. **Apply search and filters** — Module: `PropertyFilter / FilterPanel`. Text, rent, size, property type, location
4. **Matching property found?** — Module: `ExplorePage / detail lookup`. False: no-results / record-not-found state
5. **Open property details** — Module: `PropertyDetailPage`. Address, rent, area, coordinates, image URL

API verifies bearer token. Imported data is not proof of current availability or administrator verification.

#### E05 — Preferences and current shortlist

**Status:** CONNECTED WEB. **References:** REQ-402,403,404 (partial).

1. **Set business preferences** — Module: `BusinessPreferences / preferences page`. Budget, floor area, location, property type
2. **Apply preference bounds** — Module: `DatasetRecommendationRepository`. Read current property catalogue
3. **Candidate matches all bounds?** — Module: `DatasetRecommendationRepository`. False: exclude candidate; empty results possible
4. **Sort suitability index descending** — Module: `DatasetRecommendationRepository`. Workbook index is already 0–100
5. **Display highest 10 candidates** — Module: `RecommendationsPage`. Factual matching reasons; browser state

Mobile uses RecommendationRepositoryImpl demo filtering/ranking. Preferences are not saved to PostgreSQL.

#### E06 — Documented AI scoring and history

**Status:** SPEC / NOT CONNECTED. **References:** REQ-401–405; UC107.

1. **Retrieve preferences and properties** — Module: `AI Recommendation Module`. Specification inputs
2. **Retrieve geospatial features** — Module: `Data Processing and Geospatial Intelligence`. Specification inputs
3. **Predict location suitability** — Module: `Positive-Unlabeled Learning`. Not invoked by either current app locator
4. **Rank and refresh recommendations** — Module: `Property Suitability Ranking`. Specification target, not current index sort
5. **Retrieve prior recommendations** — Module: `Recommendation Management Module`. No connected recommendation-history UI

Specification processing-failure and no-suitable-property alternatives are required; current web shortlist is not this AI pipeline.

#### E07 — Geospatial data preparation

**Status:** SPEC / NOT CONNECTED. **References:** REQ-301–305; UC106.

1. **Select property and coordinates** — Module: `Geospatial Intelligence Module`. Invalid coordinates: location error
2. **Retrieve population distribution** — Module: `Population Analysis`. Predefined catchment areas
3. **Retrieve nearby F&B competition** — Module: `Competitor Analysis`. Spatial competitor density
4. **Retrieve demand generators** — Module: `Demand Generator Analysis`. Malls, offices, universities, hospitals, hubs
5. **Evaluate transport accessibility** — Module: `Accessibility Analysis`. Road access and connectivity
6. **Retrieve socioeconomic indicators** — Module: `Socioeconomic Analysis`. Income / surrounding socioeconomic data

These source retrievals are independent inputs to E08; order here follows UC106. They are not live web computations.

#### E08 — Spatial indicators and explanation

**Status:** BLOCKED WEB / DEMO MOBILE. **References:** REQ-306,501–503; UC106,108.

1. **Required spatial data available?** — Module: `LocationIntelligenceService`. False: web repository throws unavailable
2. **Prepare suitability indicators** — Module: `Location Suitability Analysis`. Specification target; mobile uses demo data
3. **Request factor contributions** — Module: `Recommendation Explanation`. Web UnavailableIntelligenceRepository
4. **Interpret recommendation factors** — Module: `Explainable AI Module`. No connected SHAP / explanation model
5. **Display understandable explanation** — Module: `ExplanationPage`. Current web shows failure/unavailable state

True path describes the specification. Web does not fabricate competitor, demand or contribution values.

#### E09 — Map exploration and spatial layers

**Status:** PARTIAL / PROTOTYPE. **References:** REQ-601–609; UC109.

1. **Open map / map view** — Module: `MapPage / ExplorePage`. Stylised projection; no map SDK
2. **Show and select property markers** — Module: `Map rendering / selection state`. Coordinates from current repository
3. **Choose geographic overlay** — Module: `Spatial Layer Management`. Competitors, demand, nearby property
4. **Retrieve transit and demographics** — Module: `Interactive Map Module`. Layer data not connected
5. **Selected layer available?** — Module: `Map UI / layer availability`. False: disabled or unavailable layer

Specification also requires map-load error handling and location-corresponding overlays. Mobile uses SitewiseMapPanel prototype.

#### E10 — Save, view and remove favourites

**Status:** LOCAL STATE. **References:** REQ-701–703; UC110.

1. **Select available property** — Module: `Property detail / PropertyCard`. Property identifier
2. **Toggle saved membership** — Module: `AppCubit.toggleSaved`. Set semantics prevent duplicate IDs
3. **Open saved properties** — Module: `SavedPage / mobile saved page`. Resolve selected IDs against repository
4. **Remove saved property** — Module: `AppCubit.toggleSaved`. Emit updated immutable state

Web selections survive only in current browser session; mobile selections are AppCubit state. No persistent favourites endpoint is wired.

#### E11 — Compare property alternatives

**Status:** LOCAL STATE. **References:** Current repository / specification module inventory.

1. **Choose comparison property** — Module: `PropertyCard / detail actions`. Property identifier
2. **Removing item or fewer than 3?** — Module: `AppCubit.toggleCompared`. False: adding fourth property is ignored
3. **Update comparison set** — Module: `AppCubit / AppState`. True: add or remove identifier
4. **View or clear comparison** — Module: `ComparePage / clearCompared`. Current property characteristics

Comparison does not create a persisted assessment, prediction, or database record.

#### E12 — Approved virtual-tour viewing

**Status:** LOCAL / DEMO. **References:** REQ-801–804; UC111.

1. **Open property tour route** — Module: `TourPage / mobile tour page`. Selected property identifier
2. **Resolve published tour** — Module: `TourService.tourForPropertyApproved`. TourRepositoryImpl in each app process
3. **Approved and published tour exists?** — Module: `TourRepositoryImpl.getTourByProperty`. False: tour unavailable
4. **View panorama / navigate controls** — Module: `Virtual-tour UI`. Local/demo media; imported records have no tour

Approval gate exists in shared code. No mobile-to-web media synchronization or storage upload is connected.

#### E13 — Location evaluation report

**Status:** BLOCKED WEB / DEMO MOBILE. **References:** Current repository / specification module inventory.

1. **Open evaluation report** — Module: `ReportPage / mobile report page`. Selected property identifier
2. **Load property information** — Module: `PropertyService.detail`. Rent, area, type and verification
3. **Request location analysis** — Module: `RecommendationService.analysis`. Web repository throws UnsupportedError
4. **Prepare summary and evidence** — Module: `Reporting Module`. Supporting factors, limits, unknowns

Web report depends on missing analysis and may remain at “Generating report”; it does not produce a complete live analysis.

#### E14 — Extended business-assessment modules

**Status:** SPEC INVENTORY. **References:** Current repository / specification module inventory.

1. **Assessment Orchestration Module** — Module: `Specification §1.6`. No connected role route identified
2. **Adaptive Questionnaire Module** — Module: `Specification §1.6`. No ordered workflow specified here
3. **Evidence Processing Module** — Module: `Specification §1.6`. No connected app data touchpoint
4. **Decision Analysis Module** — Module: `Deterministic Decision Engine`. Not the catalogue ranking implementation
5. **Knowledge Management / AI-RAG** — Module: `Specification §1.6`. Knowledge retrieval and business explanation
6. **Business Assessment Report** — Module: `Reporting Module`. Specification lists scope; no invented events

Inventory blocks are parallel named modules, not a claimed executable sequence. Detailed ordering is not established by the inspected source.

### PROPERTY OWNER

#### O01 — Web identity and owner access

**Status:** CONNECTED. **References:** REQ-102,105.

1. **Sign in with Google or email** — Module: `WebAuth / Supabase SDK`. PKCE callback: /auth/callback
2. **Valid access token?** — Module: `Express authentication middleware`. False: HTTP 401; service outage: 503
3. **Load or create role profile** — Module: `POST /api/me`. UUID, email, name; existing role preserved
4. **URL role matches profile?** — Module: `Jaspr Router redirect`. False: redirect to assigned role home
5. **Open owner workspace** — Module: `SitewiseApp / AppLayout`. True: role route is displayed

New profile may select owner. Owner identity does not link imported workbook rows to that account.

#### O02 — Mobile onboarding and owner entry

**Status:** LOCAL / DEMO. **References:** Current repository / specification module inventory.

1. **Onboarding completed?** — Module: `AppStartGate`. False: /onboarding; persist completion
2. **Local session exists?** — Module: `AuthRepositoryImpl.currentUser`. False: /auth; local/demo sign-in
3. **Resolve local user role** — Module: `AppCubit.setRole`. Demo role menu can switch roles
4. **Navigate to role home** — Module: `AppRoutes`. Named routes; no production role API

Mobile owner scope is DemoData.demoOwnerId; demo role switching is not production authorization.

#### O03 — Owner dashboard and listing status

**Status:** MIXED. **References:** REQ-208.

1. **Load owner workspace** — Module: `OwnerCubit.load`. Owner user identifier
2. **Find properties belonging to owner** — Module: `PropertyService.ownerListings`. Web: empty list; mobile: demo owner rows
3. **Apply text and status filters** — Module: `OwnerCubit.filteredProperties`. Draft / pending / verified / rejected
4. **Inspect listing and statistics** — Module: `Owner properties / detail pages`. Counts derived from repository rows

Web ApiPropertyRepository.getPropertiesByOwner returns []; imported records carry empty ownerId.

#### O04 — Add and update commercial listing

**Status:** BLOCKED WEB / MOBILE UI ONLY. **References:** REQ-201,202; UC104.

1. **Choose add or edit listing** — Module: `AddPropertyPage / mobile Stepper`. Existing identifier for edit
2. **Enter basics and location** — Module: `Listing form`. Title, address, city / location
3. **Enter commercial details** — Module: `Listing form`. Monthly rent, area, type
4. **Required form values valid?** — Module: `Form validators`. False: display errors; correct inputs
5. **Attempt create or update** — Module: `PropertyService.create / update`. Web read-only repository rejects write
6. **Show draft result** — Module: `Mobile Stepper confirmation`. Mobile currently confirms and returns; no write

Specification requires validated data storage. The final mobile confirmation is not persisted listing creation.

#### O05 — Property images and deletion

**Status:** SPEC / NOT CONNECTED. **References:** REQ-203,207; UC104 A1–A4.

1. **Choose listing image content** — Module: `Commercial Property Management`. REQ-207: image upload requirement
2. **Supported format and size?** — Module: `Specification upload validation`. False: reject input / retry upload
3. **Store uploaded listing images** — Module: `Property image storage requirement`. No connected owner upload endpoint
4. **Request listing deletion** — Module: `Commercial Property Management`. REQ-203: owner-scoped removal
5. **Owner confirms deletion?** — Module: `Specification confirmation prompt`. False: retain listing; return to management
6. **Delete or mark listing removed** — Module: `Property persistence requirement`. No shared PropertyRepository delete method

True paths describe the specification only. Existing catalogue uses external image URLs; no Supabase Storage upload occurs.

#### O06 — Submit listing and observe review

**Status:** LOCAL MOBILE / BLOCKED WEB. **References:** REQ-208,902.

1. **Open listing detail** — Module: `Owner property detail page`. Selected listing identifier
2. **Submit for verification** — Module: `OwnerCubit.submit / PropertyService.submit`. Local call: submitForVerification(id)
3. **Set listing status pending** — Module: `PropertyRepositoryImpl`. Mobile in-memory; web throws read-only
4. **Read subsequent review status** — Module: `Owner listings / status filter`. Local shared repository only

Event L1: pending listing can enter administrator queue within the same mobile process. No HTTP submission API exists.

#### O07 — Capture panorama frames on mobile

**Status:** DEVICE LOCAL. **References:** Current repository / specification module inventory.

1. **Open capture for property** — Module: `PanoramaCapturePage`. /owner/capture; property identifier
2. **Initialize camera and AR guidance** — Module: `ArCaptureService / PanoramaCaptureService`. Platform camera / sensor boundary
3. **Capture guided target sequence** — Module: `PanoramaCaptureViewModel`. 26 capture targets
4. **Store frames and session metadata** — Module: `CaptureFrameStore / CaptureSessionStore`. On-device paths and ordered frame indices
5. **Prepare generation request** — Module: `PanoramaGenerationService`. Tour draft and captured frame list

Native camera, AR and stitching require hands-on device verification. Web has no capture implementation.

#### O08 — Validate and stitch panorama

**Status:** DEVICE LOCAL. **References:** Current repository / specification module inventory.

1. **At least 26 unique frame indices?** — Module: `PanoramaGenerationService`. False: insufficient or duplicate frame error
2. **Read and decode each frame** — Module: `OpenCvPanoramaStitcher`. Missing or invalid file: preserve source frames
3. **Run panorama stitching** — Module: `OpenCV StitcherMode.PANORAMA`. Native stitchAsync operation
4. **Stitch and nonempty output succeed?** — Module: `OpenCvPanoramaStitcher`. False: explain failure; retry / retake frames
5. **Write panorama.jpg and ready status** — Module: `File system / TourRepositoryImpl`. Record output path; local tour metadata

Output is local media plus in-memory tour state; there is no backend upload or inter-device sharing.

#### O09 — Preview, regenerate and submit tour

**Status:** LOCAL / DEMO. **References:** REQ-805–807; UC111.

1. **Open tour preview / manage tours** — Module: `TourPreviewViewModel / preview pages`. Owner tour identifier
2. **Regenerate or retake content** — Module: `PanoramaGenerationService`. Mobile uses stored frames; web has zero frames
3. **Generated panorama path exists?** — Module: `TourService.submitTour`. False: generate panorama before submitting
4. **Submit tour for verification** — Module: `TourService.submitTour`. Set pendingVerification in local repository
5. **Observe approved or rejected state** — Module: `OwnerCubit / tours page`. Rejection permits retake and resubmission

Event T1: pendingTours() exposes submission to admin within same repository instance. No upload API is called.

#### O10 — Delete virtual tour

**Status:** LOCAL / DEMO. **References:** REQ-808; UC111 A3.

1. **Request deletion** — Module: `Tours / preview UI`. Select tour identifier
2. **Confirm delete action?** — Module: `Confirmation dialog`. False: cancel; retain tour
3. **Purge local capture frames** — Module: `TourService.purgeFrames`. Mobile hook; web has no frame files
4. **Remove tour metadata** — Module: `TourRepositoryImpl.deleteTour`. In-memory removal

Specification says authorized owner may delete an unpublished tour; current shared service itself does not enforce an unpublished-only guard.

#### O11 — Owner profile and session maintenance

**Status:** MIXED. **References:** REQ-103,104,106.

1. **Open and edit profile form** — Module: `Owner ProfilePage`. Web form state; no profile update endpoint
2. **Save display confirmation** — Module: `Profile UI state`. Does not persist edited profile fields
3. **Sign out on selected platform** — Module: `WebAuth / AuthService`. Web: Supabase; mobile: delete local session

Password reset is disabled on web. Owner profile editing is not database account management.

### ADMINISTRATOR

#### A01 — Administrator authentication and access

**Status:** CONNECTED WEB. **References:** REQ-102,105.

1. **Sign in with Google or email** — Module: `WebAuth / Supabase SDK`. PKCE callback: /auth/callback
2. **Valid access token?** — Module: `Express authentication middleware`. False: HTTP 401; service outage: 503
3. **Load or create role profile** — Module: `POST /api/me`. UUID, email, name; existing role preserved
4. **URL role matches profile?** — Module: `Jaspr Router redirect`. False: redirect to assigned role home
5. **Open administrator workspace** — Module: `SitewiseApp / AppLayout`. True: role route is displayed

Only a trusted local database operator assigns admin in sitewise_app.profiles; self-service signup cannot do so.

#### A02 — Mobile administrator demo entry

**Status:** LOCAL / DEMO. **References:** Current repository / specification module inventory.

1. **Onboarding completed?** — Module: `AppStartGate`. False: /onboarding; persist completion
2. **Local session exists?** — Module: `AuthRepositoryImpl.currentUser`. False: /auth; local/demo sign-in
3. **Resolve local user role** — Module: `AppCubit.setRole`. Demo role menu can switch roles
4. **Navigate to role home** — Module: `AppRoutes`. Named routes; no production role API

Admin mobile routes are demo workflows; role menu switches AppCubit state.

#### A03 — Dashboard and listing oversight

**Status:** MIXED. **References:** REQ-906.

1. **Open administrator dashboard** — Module: `AdminCubit.loadDashboard`. Load queue, listings and users
2. **Load pending property queue** — Module: `VerificationService.queue`. Web: imported records mapped pending
3. **Load catalogue and account list** — Module: `PropertyService / UserRepositoryImpl`. Web properties live; account list demo
4. **Derive status counts and listings** — Module: `AdminCubit / dashboard UI`. Search and inspect listing detail

Dataset quality PASS is not admin approval. Activity/monitoring displays are not a durable audit log.

#### A04 — Review, approve or reject listing

**Status:** LOCAL MOBILE / BLOCKED WEB. **References:** REQ-902; UC112.

1. **Choose pending property** — Module: `VerificationPage / detail page`. Local event L1: pending listing
2. **Inspect submitted record** — Module: `Property detail / review UI`. No connected document upload pipeline
3. **Administrator chooses approval?** — Module: `VerificationService`. False: reject with reason input
4. **True: mark property verified** — Module: `VerificationRepositoryImpl.verify`. Mobile local mutation; web read-only error
5. **False: mark property rejected** — Module: `VerificationRepositoryImpl.reject`. Mobile local mutation; web read-only error

Branches are alternatives, not sequential approvals. Reason is passed but not persisted by PropertyRepository; no email or notification is sent.

#### A05 — Review and moderate virtual tours

**Status:** LOCAL / DEMO. **References:** REQ-903; UC112.

1. **Load submitted tours** — Module: `AdminCubit.loadPendingTours`. TourRepositoryImpl.pendingTours
2. **Inspect submitted tour content** — Module: `Verification UI / tour data`. Local event T1: pendingVerification
3. **Administrator chooses approval?** — Module: `TourService`. False: rejection branch
4. **True: approve and publish** — Module: `TourService.approveTour`. approved; published = true
5. **False: reject and unpublish** — Module: `TourService.rejectTour`. rejected; published = false
6. **Remove tour when requested** — Module: `TourService.deleteTour`. Service exists; admin removal UI not established

Event T2: approved and published tour resolves through entrepreneur visibility gate in same app instance. No cross-device propagation.

#### A06 — Account inspection and management

**Status:** DEMO READ / SPEC WRITE. **References:** REQ-901; UC112.

1. **Open users and search accounts** — Module: `AdminCubit.loadUsers / filteredUsers`. UserRepositoryImpl returns DemoData.users
2. **Select account details** — Module: `UserDetailPage / mobile user detail`. Name, email, role, status, joined date
3. **Manage account lifecycle** — Module: `Administration Module`. Specification requirement; no connected write API

The administrator user list is separate from live sitewise_app.profiles; it is not a view of Supabase Auth users.

#### A07 — Recommendation monitoring

**Status:** SPEC / NOT CONNECTED. **References:** REQ-904; UC112.

1. **Request recommendation monitoring** — Module: `Administration Module`. Specification administrative operation
2. **Monitoring information available?** — Module: `Recommendation monitoring requirement`. False: monitoring information unavailable
3. **Display available ranking results** — Module: `AI Recommendation Monitoring`. No registered admin monitoring route identified

No prediction monitoring API is invoked by the current administrator app.

#### A08 — Explanation monitoring

**Status:** SPEC / NOT CONNECTED. **References:** REQ-905; UC112.

1. **Request explanation monitoring** — Module: `Administration Module`. Specification administrative operation
2. **Explanation evidence available?** — Module: `Explanation monitoring requirement`. False: monitoring information unavailable
3. **Inspect explanations and factors** — Module: `Recommendation Explanation Monitoring`. No connected administrator monitoring route

Existing explanation backend source is not an application integration.

#### A09 — Administrator profile and logout

**Status:** MIXED. **References:** REQ-103,104,106.

1. **Edit profile fields** — Module: `Administrator ProfilePage`. Web save sets local confirmation state
2. **Show profile updated message** — Module: `Profile UI`. No persistent profile update request
3. **Sign out** — Module: `WebAuth / mobile AuthService`. Supabase logout or local session deletion

No automatic administrator approval, privilege escalation or trusted-role assignment UI is implemented.
