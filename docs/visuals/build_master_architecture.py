"""Deterministic, editable architecture artwork; no application code is changed."""
from pathlib import Path
import json, textwrap, html

OUT = Path(__file__).parent
W, ROW, LABEL, X0, NW, GAP = 3600, 250, 285, 310, 455, 58
roles = []
def s(action, module, detail='', gate=False):
    return dict(action=action, module=module, detail=detail, gate=gate)
def g(action, module, false):
    return s(action,module,false,True)
def track(code,title,status,steps,note='',refs=''):
    return dict(code=code,title=title,status=status,steps=steps,note=note,refs=refs)

common_web = lambda role: [s('Sign in with Google or email','WebAuth / Supabase SDK','PKCE callback: /auth/callback'),g('Valid access token?','Express authentication middleware','False: HTTP 401; service outage: 503'),s('Load or create role profile','POST /api/me','UUID, email, name; existing role preserved'),g('URL role matches profile?','Jaspr Router redirect','False: redirect to assigned role home'),s('Open '+role+' workspace','SitewiseApp / AppLayout','True: role route is displayed')]
common_mobile = [g('Onboarding completed?','AppStartGate','False: /onboarding; persist completion'),g('Local session exists?','AuthRepositoryImpl.currentUser','False: /auth; local/demo sign-in'),s('Resolve local user role','AppCubit.setRole','Demo role menu can switch roles'),s('Navigate to role home','AppRoutes','Named routes; no production role API')]

E=[]
E.append(track('E01','Web identity and role access','CONNECTED',common_web('entrepreneur'),'Signup allows entrepreneur or owner; metadata cannot grant administrator.','REQ-101,102,105'))
E.append(track('E02','Mobile startup and authentication','LOCAL / DEMO',common_mobile,'Email password length is checked; demo account matching is not real password authentication. Provider login is simulated.','REQ-101,102,105'))
E.append(track('E03','Account maintenance and logout','MIXED',[s('Open profile / edit fields','ProfilePage / mobile profile','Profile edits are prototype UI state'),s('Request password reset','ForgotPasswordPage','Web validates email; sends no reset email'),s('Sign out of web','WebAuth.signout','Supabase signOut; /login'),s('Sign out of mobile','AuthService / local repository','Delete session.json; /auth')],'These are independent account actions, not mandatory sequential tasks.','REQ-103,104,106'))
E.append(track('E04','Catalogue search, filters and detail','CONNECTED WEB',[s('Open dashboard / explore','EntrepreneurCubit / PropertyService','Web: imported catalogue; mobile: demo'),s('Fetch catalogue pages','ApiPropertyRepository','GET /api/catalog/properties; limit 200'),s('Apply search and filters','PropertyFilter / FilterPanel','Text, rent, size, property type, location'),g('Matching property found?','ExplorePage / detail lookup','False: no-results / record-not-found state'),s('Open property details','PropertyDetailPage','Address, rent, area, coordinates, image URL')],'API verifies bearer token. Imported data is not proof of current availability or administrator verification.','REQ-204,205,206; UC105'))
E.append(track('E05','Preferences and current shortlist','CONNECTED WEB',[s('Set business preferences','BusinessPreferences / preferences page','Budget, floor area, location, property type'),s('Apply preference bounds','DatasetRecommendationRepository','Read current property catalogue'),g('Candidate matches all bounds?','DatasetRecommendationRepository','False: exclude candidate; empty results possible'),s('Sort suitability index descending','DatasetRecommendationRepository','Workbook index is already 0–100'),s('Display highest 10 candidates','RecommendationsPage','Factual matching reasons; browser state')],'Mobile uses RecommendationRepositoryImpl demo filtering/ranking. Preferences are not saved to PostgreSQL.','REQ-402,403,404 (partial)'))
E.append(track('E06','Documented AI scoring and history','SPEC / NOT CONNECTED',[s('Retrieve preferences and properties','AI Recommendation Module','Specification inputs'),s('Retrieve geospatial features','Data Processing and Geospatial Intelligence','Specification inputs'),s('Predict location suitability','Positive-Unlabeled Learning','Not invoked by either current app locator'),s('Rank and refresh recommendations','Property Suitability Ranking','Specification target, not current index sort'),s('Retrieve prior recommendations','Recommendation Management Module','No connected recommendation-history UI')],'Specification processing-failure and no-suitable-property alternatives are required; current web shortlist is not this AI pipeline.','REQ-401–405; UC107'))
E.append(track('E07','Geospatial data preparation','SPEC / NOT CONNECTED',[s('Select property and coordinates','Geospatial Intelligence Module','Invalid coordinates: location error'),s('Retrieve population distribution','Population Analysis','Predefined catchment areas'),s('Retrieve nearby F&B competition','Competitor Analysis','Spatial competitor density'),s('Retrieve demand generators','Demand Generator Analysis','Malls, offices, universities, hospitals, hubs'),s('Evaluate transport accessibility','Accessibility Analysis','Road access and connectivity'),s('Retrieve socioeconomic indicators','Socioeconomic Analysis','Income / surrounding socioeconomic data')],'These source retrievals are independent inputs to E08; order here follows UC106. They are not live web computations.','REQ-301–305; UC106'))
E.append(track('E08','Spatial indicators and explanation','BLOCKED WEB / DEMO MOBILE',[g('Required spatial data available?','LocationIntelligenceService','False: web repository throws unavailable'),s('Prepare suitability indicators','Location Suitability Analysis','Specification target; mobile uses demo data'),s('Request factor contributions','Recommendation Explanation','Web UnavailableIntelligenceRepository'),s('Interpret recommendation factors','Explainable AI Module','No connected SHAP / explanation model'),s('Display understandable explanation','ExplanationPage','Current web shows failure/unavailable state')],'True path describes the specification. Web does not fabricate competitor, demand or contribution values.','REQ-306,501–503; UC106,108'))
E.append(track('E09','Map exploration and spatial layers','PARTIAL / PROTOTYPE',[s('Open map / map view','MapPage / ExplorePage','Stylised projection; no map SDK'),s('Show and select property markers','Map rendering / selection state','Coordinates from current repository'),s('Choose geographic overlay','Spatial Layer Management','Competitors, demand, nearby property'),s('Retrieve transit and demographics','Interactive Map Module','Layer data not connected'),g('Selected layer available?','Map UI / layer availability','False: disabled or unavailable layer')],'Specification also requires map-load error handling and location-corresponding overlays. Mobile uses SitewiseMapPanel prototype.','REQ-601–609; UC109'))
E.append(track('E10','Save, view and remove favourites','LOCAL STATE',[s('Select available property','Property detail / PropertyCard','Property identifier'),s('Toggle saved membership','AppCubit.toggleSaved','Set semantics prevent duplicate IDs'),s('Open saved properties','SavedPage / mobile saved page','Resolve selected IDs against repository'),s('Remove saved property','AppCubit.toggleSaved','Emit updated immutable state')],'Web selections survive only in current browser session; mobile selections are AppCubit state. No persistent favourites endpoint is wired.','REQ-701–703; UC110'))
E.append(track('E11','Compare property alternatives','LOCAL STATE',[s('Choose comparison property','PropertyCard / detail actions','Property identifier'),g('Removing item or fewer than 3?','AppCubit.toggleCompared','False: adding fourth property is ignored'),s('Update comparison set','AppCubit / AppState','True: add or remove identifier'),s('View or clear comparison','ComparePage / clearCompared','Current property characteristics')],'Comparison does not create a persisted assessment, prediction, or database record.'))
E.append(track('E12','Approved virtual-tour viewing','LOCAL / DEMO',[s('Open property tour route','TourPage / mobile tour page','Selected property identifier'),s('Resolve published tour','TourService.tourForPropertyApproved','TourRepositoryImpl in each app process'),g('Approved and published tour exists?','TourRepositoryImpl.getTourByProperty','False: tour unavailable'),s('View panorama / navigate controls','Virtual-tour UI','Local/demo media; imported records have no tour')],'Approval gate exists in shared code. No mobile-to-web media synchronization or storage upload is connected.','REQ-801–804; UC111'))
E.append(track('E13','Location evaluation report','BLOCKED WEB / DEMO MOBILE',[s('Open evaluation report','ReportPage / mobile report page','Selected property identifier'),s('Load property information','PropertyService.detail','Rent, area, type and verification'),s('Request location analysis','RecommendationService.analysis','Web repository throws UnsupportedError'),s('Prepare summary and evidence','Reporting Module','Supporting factors, limits, unknowns')],'Web report depends on missing analysis and may remain at “Generating report”; it does not produce a complete live analysis.'))
E.append(track('E14','Extended business-assessment modules','SPEC INVENTORY',[s('Assessment Orchestration Module','Specification §1.6','No connected role route identified'),s('Adaptive Questionnaire Module','Specification §1.6','No ordered workflow specified here'),s('Evidence Processing Module','Specification §1.6','No connected app data touchpoint'),s('Decision Analysis Module','Deterministic Decision Engine','Not the catalogue ranking implementation'),s('Knowledge Management / AI-RAG','Specification §1.6','Knowledge retrieval and business explanation'),s('Business Assessment Report','Reporting Module','Specification lists scope; no invented events')],'Inventory blocks are parallel named modules, not a claimed executable sequence. Detailed ordering is not established by the inspected source.'))

O=[]
O.append(track('O01','Web identity and owner access','CONNECTED',common_web('owner'),'New profile may select owner. Owner identity does not link imported workbook rows to that account.','REQ-102,105'))
O.append(track('O02','Mobile onboarding and owner entry','LOCAL / DEMO',common_mobile,'Mobile owner scope is DemoData.demoOwnerId; demo role switching is not production authorization.'))
O.append(track('O03','Owner dashboard and listing status','MIXED',[s('Load owner workspace','OwnerCubit.load','Owner user identifier'),s('Find properties belonging to owner','PropertyService.ownerListings','Web: empty list; mobile: demo owner rows'),s('Apply text and status filters','OwnerCubit.filteredProperties','Draft / pending / verified / rejected'),s('Inspect listing and statistics','Owner properties / detail pages','Counts derived from repository rows')],'Web ApiPropertyRepository.getPropertiesByOwner returns []; imported records carry empty ownerId.','REQ-208'))
O.append(track('O04','Add and update commercial listing','BLOCKED WEB / MOBILE UI ONLY',[s('Choose add or edit listing','AddPropertyPage / mobile Stepper','Existing identifier for edit'),s('Enter basics and location','Listing form','Title, address, city / location'),s('Enter commercial details','Listing form','Monthly rent, area, type'),g('Required form values valid?','Form validators','False: display errors; correct inputs'),s('Attempt create or update','PropertyService.create / update','Web read-only repository rejects write'),s('Show draft result','Mobile Stepper confirmation','Mobile currently confirms and returns; no write')],'Specification requires validated data storage. The final mobile confirmation is not persisted listing creation.','REQ-201,202; UC104'))
O.append(track('O05','Property images and deletion','SPEC / NOT CONNECTED',[s('Choose listing image content','Commercial Property Management','REQ-207: image upload requirement'),g('Supported format and size?','Specification upload validation','False: reject input / retry upload'),s('Store uploaded listing images','Property image storage requirement','No connected owner upload endpoint'),s('Request listing deletion','Commercial Property Management','REQ-203: owner-scoped removal'),g('Owner confirms deletion?','Specification confirmation prompt','False: retain listing; return to management'),s('Delete or mark listing removed','Property persistence requirement','No shared PropertyRepository delete method')],'True paths describe the specification only. Existing catalogue uses external image URLs; no Supabase Storage upload occurs.','REQ-203,207; UC104 A1–A4'))
O.append(track('O06','Submit listing and observe review','LOCAL MOBILE / BLOCKED WEB',[s('Open listing detail','Owner property detail page','Selected listing identifier'),s('Submit for verification','OwnerCubit.submit / PropertyService.submit','Local call: submitForVerification(id)'),s('Set listing status pending','PropertyRepositoryImpl','Mobile in-memory; web throws read-only'),s('Read subsequent review status','Owner listings / status filter','Local shared repository only')],'Event L1: pending listing can enter administrator queue within the same mobile process. No HTTP submission API exists.','REQ-208,902'))
O.append(track('O07','Capture panorama frames on mobile','DEVICE LOCAL',[s('Open capture for property','PanoramaCapturePage','/owner/capture; property identifier'),s('Initialize camera and AR guidance','ArCaptureService / PanoramaCaptureService','Platform camera / sensor boundary'),s('Capture guided target sequence','PanoramaCaptureViewModel','26 capture targets'),s('Store frames and session metadata','CaptureFrameStore / CaptureSessionStore','On-device paths and ordered frame indices'),s('Prepare generation request','PanoramaGenerationService','Tour draft and captured frame list')],'Native camera, AR and stitching require hands-on device verification. Web has no capture implementation.'))
O.append(track('O08','Validate and stitch panorama','DEVICE LOCAL',[g('At least 26 unique frame indices?','PanoramaGenerationService','False: insufficient or duplicate frame error'),s('Read and decode each frame','OpenCvPanoramaStitcher','Missing or invalid file: preserve source frames'),s('Run panorama stitching','OpenCV StitcherMode.PANORAMA','Native stitchAsync operation'),g('Stitch and nonempty output succeed?','OpenCvPanoramaStitcher','False: explain failure; retry / retake frames'),s('Write panorama.jpg and ready status','File system / TourRepositoryImpl','Record output path; local tour metadata')],'Output is local media plus in-memory tour state; there is no backend upload or inter-device sharing.'))
O.append(track('O09','Preview, regenerate and submit tour','LOCAL / DEMO',[s('Open tour preview / manage tours','TourPreviewViewModel / preview pages','Owner tour identifier'),s('Regenerate or retake content','PanoramaGenerationService','Mobile uses stored frames; web has zero frames'),g('Generated panorama path exists?','TourService.submitTour','False: generate panorama before submitting'),s('Submit tour for verification','TourService.submitTour','Set pendingVerification in local repository'),s('Observe approved or rejected state','OwnerCubit / tours page','Rejection permits retake and resubmission')],'Event T1: pendingTours() exposes submission to admin within same repository instance. No upload API is called.','REQ-805–807; UC111'))
O.append(track('O10','Delete virtual tour','LOCAL / DEMO',[s('Request deletion','Tours / preview UI','Select tour identifier'),g('Confirm delete action?','Confirmation dialog','False: cancel; retain tour'),s('Purge local capture frames','TourService.purgeFrames','Mobile hook; web has no frame files'),s('Remove tour metadata','TourRepositoryImpl.deleteTour','In-memory removal')],'Specification says authorized owner may delete an unpublished tour; current shared service itself does not enforce an unpublished-only guard.','REQ-808; UC111 A3'))
O.append(track('O11','Owner profile and session maintenance','MIXED',[s('Open and edit profile form','Owner ProfilePage','Web form state; no profile update endpoint'),s('Save display confirmation','Profile UI state','Does not persist edited profile fields'),s('Sign out on selected platform','WebAuth / AuthService','Web: Supabase; mobile: delete local session')],'Password reset is disabled on web. Owner profile editing is not database account management.','REQ-103,104,106'))

A=[]
A.append(track('A01','Administrator authentication and access','CONNECTED WEB',common_web('administrator'),'Only a trusted local database operator assigns admin in sitewise_app.profiles; self-service signup cannot do so.','REQ-102,105'))
A.append(track('A02','Mobile administrator demo entry','LOCAL / DEMO',common_mobile,'Admin mobile routes are demo workflows; role menu switches AppCubit state.'))
A.append(track('A03','Dashboard and listing oversight','MIXED',[s('Open administrator dashboard','AdminCubit.loadDashboard','Load queue, listings and users'),s('Load pending property queue','VerificationService.queue','Web: imported records mapped pending'),s('Load catalogue and account list','PropertyService / UserRepositoryImpl','Web properties live; account list demo'),s('Derive status counts and listings','AdminCubit / dashboard UI','Search and inspect listing detail')],'Dataset quality PASS is not admin approval. Activity/monitoring displays are not a durable audit log.','REQ-906'))
A.append(track('A04','Review, approve or reject listing','LOCAL MOBILE / BLOCKED WEB',[s('Choose pending property','VerificationPage / detail page','Local event L1: pending listing'),s('Inspect submitted record','Property detail / review UI','No connected document upload pipeline'),g('Administrator chooses approval?','VerificationService','False: reject with reason input'),s('True: mark property verified','VerificationRepositoryImpl.verify','Mobile local mutation; web read-only error'),s('False: mark property rejected','VerificationRepositoryImpl.reject','Mobile local mutation; web read-only error')],'Branches are alternatives, not sequential approvals. Reason is passed but not persisted by PropertyRepository; no email or notification is sent.','REQ-902; UC112'))
A.append(track('A05','Review and moderate virtual tours','LOCAL / DEMO',[s('Load submitted tours','AdminCubit.loadPendingTours','TourRepositoryImpl.pendingTours'),s('Inspect submitted tour content','Verification UI / tour data','Local event T1: pendingVerification'),g('Administrator chooses approval?','TourService','False: rejection branch'),s('True: approve and publish','TourService.approveTour','approved; published = true'),s('False: reject and unpublish','TourService.rejectTour','rejected; published = false'),s('Remove tour when requested','TourService.deleteTour','Service exists; admin removal UI not established')],'Event T2: approved and published tour resolves through entrepreneur visibility gate in same app instance. No cross-device propagation.','REQ-903; UC112'))
A.append(track('A06','Account inspection and management','DEMO READ / SPEC WRITE',[s('Open users and search accounts','AdminCubit.loadUsers / filteredUsers','UserRepositoryImpl returns DemoData.users'),s('Select account details','UserDetailPage / mobile user detail','Name, email, role, status, joined date'),s('Manage account lifecycle','Administration Module','Specification requirement; no connected write API')],'The administrator user list is separate from live sitewise_app.profiles; it is not a view of Supabase Auth users.','REQ-901; UC112'))
A.append(track('A07','Recommendation monitoring','SPEC / NOT CONNECTED',[s('Request recommendation monitoring','Administration Module','Specification administrative operation'),g('Monitoring information available?','Recommendation monitoring requirement','False: monitoring information unavailable'),s('Display available ranking results','AI Recommendation Monitoring','No registered admin monitoring route identified')],'No prediction monitoring API is invoked by the current administrator app.','REQ-904; UC112'))
A.append(track('A08','Explanation monitoring','SPEC / NOT CONNECTED',[s('Request explanation monitoring','Administration Module','Specification administrative operation'),g('Explanation evidence available?','Explanation monitoring requirement','False: monitoring information unavailable'),s('Inspect explanations and factors','Recommendation Explanation Monitoring','No connected administrator monitoring route')],'Existing explanation backend source is not an application integration.','REQ-905; UC112'))
A.append(track('A09','Administrator profile and logout','MIXED',[s('Edit profile fields','Administrator ProfilePage','Web save sets local confirmation state'),s('Show profile updated message','Profile UI','No persistent profile update request'),s('Sign out','WebAuth / mobile AuthService','Supabase logout or local session deletion')],'No automatic administrator approval, privilege escalation or trusted-role assignment UI is implemented.','REQ-103,104,106'))
roles=[('F&B ENTREPRENEUR','#087f8c',E),('PROPERTY OWNER','#08734d',O),('ADMINISTRATOR','#223d73',A)]

parts=[]
def add(t): parts.append(t)
def esc(t): return html.escape(str(t))
def rect(x,y,w,h,fill='white',stroke='#ccd7e3',rx=12,dash=False):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="2"'+(' stroke-dasharray="9 6"' if dash else '')+'/>')
def txt(x,y,t,size=21,color='#172b45',bold=False,anchor='start'):
    add(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{700 if bold else 400}" text-anchor="{anchor}">{esc(t)}</text>')
def lines(x,y,t,width=43,size=20,color='#172b45',bold=False,maxlines=None):
    chunks=[]
    for line in t.split('\n'): chunks.extend(textwrap.wrap(line,width=width,break_long_words=False,break_on_hyphens=False) or [''])
    for i,line in enumerate(chunks): txt(x,y+i*(size+5),line,size,color,bold)
    return len(chunks)*(size+5)
def arrow(x1,y1,x2,y2,label='',dashed=False,color='#60748e'):
    add(f'<path d="M{x1},{y1} L{x2},{y2}" fill="none" stroke="{color}" stroke-width="2.5" marker-end="url(#arrow)"'+(' stroke-dasharray="8 7"' if dashed else '')+'/>')
    if label: txt((x1+x2)/2,(y1+y2)/2-9,label,15,color,True,'middle')
def node(x,y,step,color):
    gate=step['gate']
    if gate:
        # A diamond uses its own action area; module label remains attached underneath.
        add(f'<path d="M{x+NW/2},{y} L{x+NW},{y+52} L{x+NW/2},{y+104} L{x},{y+52} Z" fill="#f0f5fa" stroke="{color}" stroke-width="2.5"/>')
        chunks=textwrap.wrap(step['action'],38)
        for j,c in enumerate(chunks): txt(x+NW/2,y+43+j*24,c,20,color,True,'middle')
    else:
        rect(x,y,NW,104,'#ffffff',color)
        lines(x+17,y+31,step['action'],39,21,bold=True)
    rect(x,y+106,NW,57,color,color,rx=5)
    lines(x+12,y+128,'Module: '+step['module'],51,17,'white',True)
    if step['detail']:
        lines(x+6,y+188,step['detail'],53,17,'#4b6079')
    if gate:
        # The explicit False branch points to its written alternate outcome.
        arrow(x+NW/2,y+164,x+NW/2,y+168)

Y=1280
starts={}
total=sum(len(r[2]) for r in roles)
H=Y+total*ROW+3*92+1050
add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Arial, Helvetica, sans-serif">')
add('<defs><pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse"><path d="M32 0H0V32" fill="none" stroke="#eaf0f5" stroke-width="1"/></pattern><marker id="arrow" markerWidth="9" markerHeight="9" refX="8" refY="4" orient="auto-start-reverse"><path d="M0 0L8 4L0 8" fill="none" stroke="#60748e" stroke-width="1.6"/></marker></defs>')
rect(0,0,W,H,'#fff','#fff',0)
add(f'<rect width="{W}" height="{H}" fill="url(#grid)"/>')
txt(50,62,'SITEWISE | MASTER MULTI-MODULE ARCHITECTURE',40,bold=True)
txt(50,101,'Exactly three role lanes • Independent workflow sub-channels • Specification versus current code • 1 November 2026',23)
txt(50,140,'SOURCE: Project specification §§1.6, 3.2, 4.4 + current web/mobile composition roots, repositories, API and schema.',20)
rect(35,166,3530,92,'#f0f5fa')
lines(55,196,'READING KEY: Each row is an independent workflow track, not a mandatory journey through all rows. Module badges identify code or named specification modules. Diamonds are gates; True continues, False follows the explicitly written alternative beneath the diamond. Approval True/False result blocks are alternatives.',166,22)
txt(50,305,'DEPLOYMENT BOUNDARIES AND DATA TOUCHPOINTS (infrastructure band; not a fourth role)',27,bold=True)
deployment=[(50,'Browser on laptop','Jaspr client • :8090 dev / :8091 preview\nHTML / CSS / Dart-generated JavaScript\nauth_client.js ↔ WebAuth bridge\nSession token: localStorage or sessionStorage'),(760,'Supabase Auth','Cloud identity provider\nGoogle OAuth PKCE or email/password\n/auth/callback returns to browser\nNo property catalogue stored here'),(1470,'Local application API','Express • 127.0.0.1:3001\nGET /api/config and GET /api/health: public\nPOST or GET /api/me: authenticated\nGET /api/catalog/properties[/:id]'),(2180,'Local PostgreSQL','sitewise_app.profiles + properties\nProfile UUID matches Supabase user UUID\nParameterized queries / transactional import\nNo favourites / uploads / tour tables here'),(2890,'Mobile device','Flutter UI and named routes\nDemo/local AuthRepositoryImpl\nLocal session and onboarding files\nCapture files; no backend connection')]
for x,title,body in deployment:
    rect(x,332,650,195,'#fff','#8296ae')
    txt(x+18,365,title,25,bold=True)
    lines(x+18,399,body,56,19)
arrow(700,400,760,400)
arrow(1410,400,1470,400)
arrow(2120,400,2180,400)
txt(55,555,'Browser → API: Authorization: Bearer access_token • API → Supabase: GET /auth/v1/user to validate the user.',20,bold=True)
txt(55,588,'Invalid/missing token: 401 • Auth service unavailable: 503 • Catalog pagination: ≤200 rows/page • Unknown property: 404.',20)
rect(50,615,2100,245,'#f5faf9','#83aca2')
txt(70,650,'Data ingestion and database payloads',25,bold=True)
lines(70,686,'Workbook Filtered_Data → prepare-property-workbook.py → ignored .data/properties.json → import-properties.js → PostgreSQL upsert by canonical ID. 2,126 accepted rows; 374 excluded; 2,004 external image URLs. No image-file upload or copying to Supabase Storage.',148,20)
lines(70,779,'properties: id, title, address, city, state, postcode, rental_rm, size_sqft, latitude, longitude, property_type, image_url, source_url, suitability_score, dataset_validation, source_workbook, source_sheet, source_row, source_data JSONB, imported_at.',151,18)
rect(2180,615,1360,245,'#f6f8fc','#9caec8')
txt(2200,650,'Role and trust boundaries',25,bold=True)
lines(2200,688,'profiles: user_id UUID, email, display_name, role, created_at. First insert can select owner or entrepreneur; existing role is preserved. Administrator is assigned by a trusted database operator. UI route redirects check profile role; catalogue API checks authentication, not per-role catalogue permissions.',104,20)
txt(50,910,'OTHER REPOSITORY SERVICES — PRESENT IN SOURCE, NOT WIRED TO CURRENT APP LOCATORS',25,bold=True)
rect(50,932,3490,220,'#f8fafc','#9eacbd',dash=True)
lines(70,970,'backend/: FastAPI /api/v1 route groups: properties, users, recommendations, suitability, saved-properties, geospatial, virtual-tours, reports. SQLModel repositories/services and ML/explanation source exist; deployment and app integration are not established by the inspected composition roots. No live app arrows point to these routes.',215,21)
lines(70,1063,'test/server.js: separate research/map API on :3000 using research data. Current application catalogue uses test/app-server.js on :3001. Shared Dart logic is a library, not a network service; each app owns independent repository instances.',218,21)
txt(50,1204,'STATUS: CONNECTED = integrated code path | LOCAL / DEMO = process/device state | BLOCKED = path cannot complete | SPEC = documented target',21,bold=True)

for title,color,tracks in roles:
    lane_start=Y
    lane_h=92+len(tracks)*ROW
    rect(30,Y,3540,lane_h,'#ffffff',color,rx=14)
    rect(30,Y,3540,78,color,color,rx=12)
    txt(53,Y+48,title,31,'white',True)
    txt(3525,Y+48,f'{len(tracks)} independent tracks',22,'white',True,'end')
    Y+=92
    for idx,t in enumerate(tracks):
        starts[t['code']]=Y
        add(f'<g id="{t["code"]}">')
        if idx%2==0: rect(32,Y,3536,ROW,'#f4f7fa','#e3e9f0',0)
        txt(50,Y+31,t['code'],24,color,True)
        lines(50,Y+61,t['title'],21,21,color,True)
        lines(50,Y+151,t['status'],24,15,color,True)
        lines(50,Y+193,t['refs'],29,13,'#60748e')
        for i,step in enumerate(t['steps']):
            x=X0+i*(NW+GAP)
            node(x,Y+12,step,color)
            if i:
                # Approval/result branches are labeled explicitly instead of a false sequential approval.
                prev=t['steps'][i-1]
                if step['action'].startswith('False:') or t['code'] in ('E03','E14','O11','A09') or (t['code']=='O05' and i==3) or (t['code']=='A05' and i==5):
                    pass
                else: arrow(x-GAP+4,Y+64,x-6,Y+64,'True' if prev['gate'] else '')
            if step['action'].startswith('False:'):
                gate_i=next((j for j,v in enumerate(t['steps']) if v['gate']),None)
                if gate_i is not None:
                    gx=X0+gate_i*(NW+GAP)+NW/2
                    add(f'<path d="M{gx},{Y+116} V{Y+237} H{x+NW/2} V{Y+176}" fill="none" stroke="{color}" stroke-width="2" marker-end="url(#arrow)"/>')
                    txt((gx+x+NW/2)/2,Y+233,'False',14,color,True)
        # Fully spelled notes remain in the searchable source ledger and viewer tooltip.
        add(f'<title>{esc(t["code"]+" — "+t["title"]+". "+t["note"])}</title>')
        add('</g>')
        Y+=ROW
    Y+=0

# Cross-lane event buses route only through reserved right-hand gutter.
txt(50,Y+52,'CROSS-ROLE INTERSECTIONS — DASHED EVENTS; NO INVENTED HTTP ENDPOINTS',28,bold=True)
events=[('L1','O06','A04','submitForVerification(id) → getPendingQueue()','Mobile in-memory property repository only; web write is blocked.'),('L2','A04','O06','verify(id) / reject(id, reason) → owner status lookup','Local status mutation only; reason is not stored and no notification is sent.'),('T1','O09','A05','submitTour(id) → pendingTours()','Same app TourRepositoryImpl instance; no network event or webhook.'),('T2','A05','E12','approveTour(id) → getTourByProperty(propertyId)','Only approved AND published tours resolve. No mobile ↔ web synchronization.')]
for i,(key,src,dst,label,note) in enumerate(events):
    x=3420+i*30
    sy=starts[src]+220; dy=starts[dst]+220
    add(f'<path d="M3370,{sy} H{x} V{dy} H3360" fill="none" stroke="#75869e" stroke-width="1.8" stroke-dasharray="7 8" marker-end="url(#arrow)"/>')
    txt(x+3,sy-5,key,13,'#526881',True)
    yy=Y+91+i*72
    txt(65,yy,f'{key}  {src} → {dst}: {label}',22,bold=True)
    txt(110,yy+27,note,19)
Y+=415
rect(50,Y,3490,120,'#f0f5fa')
lines(70,Y+35,'SPECIFICATION HANDOFF: owner submits content → administrator reviews → owner receives updated status → entrepreneur sees approved content. This is not an integrated deployed workflow. Dashed L/T buses above show only the actual same-instance shared-service behavior; there is no submission HTTP API, notification webhook or cross-device media transport.',218,21)
Y+=155
txt(50,Y,'SOURCE AND SCOPE NOTES',27,bold=True)
lines(50,Y+36,'Authoritative specification: RSW_JOELTANHOUJUN_Project1.pdf, §§1.6, 3.2.1, 4.4.1–4.4.9. Current implementation takes precedence over older repository audit claims. Required-but-unconnected modules are kept visible rather than depicted as deployed components. Parallel source retrievals and independent account actions are explicitly labelled in the companion ledger.',218,20)
lines(50,Y+132,'See sitewise-master-workflows.json and sitewise-master-architecture-notes.md for every track note, exact branch interpretation, source paths and known UI limitations. This artifact describes code and requirements; it does not certify live deployment, security completeness, model performance or successful device tests.',218,20)
add('</svg>')
OUT.joinpath('sitewise-master-architecture.svg').write_text('\n'.join(parts),encoding='utf-8')
OUT.joinpath('sitewise-master-workflows.json').write_text(json.dumps(dict(roles=[dict(role=r,color=c,tracks=t) for r,c,t in roles],events=events),indent=2,ensure_ascii=False),encoding='utf-8')
notes=['# Sitewise master architecture — source and workflow ledger','',
       'Snapshot: 1 November 2026. Exactly three primary role lanes; 34 independent tracks and 153 module-labelled blocks. The diagram combines documented requirements with their current implementation status. It is not a certification of production readiness.', '',
       'Primary specification: `C:/Users/Lenovo/OneDrive/Desktop/RSW_JOELTANHOUJUN_Project1.pdf`, §§1.6, 3.2.1 and 4.4.1–4.4.9. Read directly with PyMuPDF. Current source takes precedence over the older implementation audit. No payments, bookings, notification service or production cloud deployment was inferred.', '',
       'Code sources: `fyp_jaspr_web/lib/app.dart`, `lib/data/app_locator.dart`, `lib/data/api_property_repository.dart`, `tool/auth_client.js`; `fyp_mobile_app/lib/core/routing/app_routes.dart`, `lib/application/services/service_locator.dart`, `lib/presentation/mobile/start/app_start_gate.dart`, `lib/data/repositories/auth_repository_impl.dart`; shared `AppCubit`, `OwnerCubit`, `AdminCubit`, `TourService`, `VerificationRepositoryImpl`, `TourRepositoryImpl`; mobile panorama generation and OpenCV stitcher; `test/app-api.js`, `test/app-schema.sql`, workbook import tools; `backend/src/sitesense/main.py` and `api/v1/router.py`.', '',
       '## Interpreting the diagram','',
       '- Each role contains parallel tracks. Reading down through tracks is not a required user journey. Account edits, reset requests and logout are independent actions.',
       '- Diamonds show explicit conditions or human approval choices. True continues right; False points to the written alternative below the gate. For approval gates, the True and False result blocks are alternative outcomes, not sequential updates.',
       '- SPEC tracks retain the documented operations without claiming deployment. The named business-assessment modules have no invented ordering or app routes.',
       '- Dashed cross-lane buses L1/L2/T1/T2 are same-process repository dependencies, not network APIs or cross-device events. The exact service method names are shown in the diagram event ledger.',
       '- Web catalogue API access is authenticated. Role checks govern web routing; no claim is made that catalogue reads are restricted by role or that persistent administrative writes exist.',
       '- Web reports currently depend on unavailable analysis; the report UI may remain in its loading state. No successful report export is claimed.',
       '- The separate FastAPI source and research API are shown as unconnected from the current app locators. Their existence does not prove deployed runtime availability.', '',
       '## Full workflow ledger','']
for role,color,tracks in roles:
    notes.extend(['### '+role,''])
    for t in tracks:
        notes.extend(['#### '+t['code']+' — '+t['title'], '', '**Status:** '+t['status']+'. **References:** '+(t['refs'] or 'Current repository / specification module inventory')+'.',''])
        for i,step in enumerate(t['steps'],1):
            notes.append(f'{i}. **{step["action"]}** — Module: `{step["module"]}`. '+step['detail'])
        notes.extend(['',t['note'],''])
OUT.joinpath('sitewise-master-architecture-notes.md').write_text('\n'.join(notes),encoding='utf-8')
svg='\n'.join(parts)
tracklinks=''.join(f'<button data-track="{t["code"]}">{esc(t["code"]+" · "+t["title"])}</button>' for _,_,ts in roles for t in ts)
viewer='''<!doctype html><html><head><meta charset="utf-8"><title>Sitewise master architecture</title><style>
*{box-sizing:border-box}body{margin:0;font-family:Arial,sans-serif;color:#172b45}header{height:68px;display:flex;align-items:center;gap:16px;padding:12px 22px;border-bottom:1px solid #d3dce8;background:white}h1{font-size:18px;margin:0}button,a{font:inherit}button{cursor:pointer;border:1px solid #c1cedd;background:white;padding:7px 12px;border-radius:6px;color:#172b45}main{display:flex;height:calc(100vh - 68px)}aside{width:330px;flex-shrink:0;overflow:auto;padding:16px;background:#f4f7fa;border-right:1px solid #d3dce8}aside button{display:block;text-align:left;width:100%;font-size:13px;margin-bottom:6px}#viewport{overflow:auto;flex:1;background:#e9eef5}#canvas{width:3600px}svg{display:block;width:100%;height:auto}#note{position:fixed;bottom:18px;right:28px;max-width:650px;background:#172b45;color:white;padding:14px 20px;border-radius:10px;display:none;font-size:15px;box-shadow:0 4px 20px #0003}p{line-height:1.5;font-size:13px}
</style></head><body><header><h1>Sitewise · Master architecture</h1><button id="fit">Fit width</button><button id="minus">−</button><span id="scale"></span><button id="plus">+</button><a href="sitewise-master-architecture.svg" download>Editable SVG</a><a href="sitewise-master-architecture.png" download>Full-size PNG</a><a href="sitewise-master-architecture-notes.md">Full workflow ledger</a></header><main><aside><strong>Three roles · 34 tracks</strong><p>Jump to a track. Click any track in the diagram to read its implementation note. Use + to inspect full module names.</p>'''+tracklinks+'''</aside><section id="viewport"><div id="canvas">'''+svg+'''</div></section></main><div id="note"></div><script>
const canvas=document.querySelector('#canvas'), viewport=document.querySelector('#viewport'),note=document.querySelector('#note');let zoom=0.5;
function apply(){canvas.style.width=(3600*zoom)+'px';document.querySelector('#scale').textContent=Math.round(zoom*100)+'%'}
document.querySelector('#fit').onclick=()=>{zoom=(viewport.clientWidth-30)/3600;apply()};document.querySelector('#plus').onclick=()=>{zoom=Math.min(2,zoom*1.25);apply()};document.querySelector('#minus').onclick=()=>{zoom=Math.max(.15,zoom/1.25);apply()};
document.querySelectorAll('[data-track]').forEach(b=>b.onclick=()=>{const g=document.getElementById(b.dataset.track);viewport.scrollTop=g.getBBox().y*zoom-20;note.textContent=g.querySelector('title').textContent;note.style.display='block'});
document.querySelectorAll('svg g[id]').forEach(g=>g.addEventListener('click',()=>{note.textContent=g.querySelector('title').textContent;note.style.display='block'}));note.onclick=()=>note.style.display='none';document.querySelector('#fit').click();
</script></body></html>'''
OUT.joinpath('sitewise-master-architecture.html').write_text(viewer,encoding='utf-8')
print(json.dumps(dict(width=W,height=H,tracks=total,nodes=sum(len(t['steps']) for _,_,ts in roles for t in ts))))
