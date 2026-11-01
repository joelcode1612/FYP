# Sitewise web app: local PostgreSQL + Supabase Auth

The Jaspr app uses client rendering: `web/index.html` loads the generated Dart
JavaScript and mounts `SitewiseApp` in `#app`. It renders normal HTML/CSS.

## Services and data flow

```text
Browser (localhost:8091, or Jaspr development on 8090)
  |-- Google / email sign-in --> Supabase Auth
  |-- Supabase access token --> local Express application API (localhost:3001)
                                 |-- verifies token with Supabase Auth
                                 |-- reads application data from local PostgreSQL
```

Supabase manages identities and browser sessions. PostgreSQL stores the property
catalogue, original workbook fields and application role profiles keyed by the
Supabase user UUID. PostgreSQL credentials stay in `test/.env`; the browser sees
only the Supabase project URL and publishable key. No Supabase secret/service-role
key is required. The older research API on port 3000 remains separate.

## Property dataset

The supplied workbook's `Filtered_Data` sheet contains **2,126 accepted records**,
with **2,004 image URLs**. The 374 `Filtered_Out` records are excluded. The import
preserves every accepted source row in JSONB alongside normalized columns, in
`sitewise_app.properties`. It does not alter existing `fyp.*` research tables.
The original image URLs are used; images are not copied into Supabase Storage.

A workbook quality PASS is not administrator verification or proof that a unit
is currently available. The source suitability index is already on a 0–100 scale.
The shortlist filters the real catalogue and sorts that source index; it is not
a trained business-success prediction. Competitor/demand explanations are shown
as unavailable rather than replaced with demo figures.

## Authentication configuration

Use `test/.env.example` as the reference. The application needs:

```dotenv
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_PUBLISHABLE_KEY=your-publishable-key
APP_API_PORT=3001
```

Keep the existing PGHOST, PGPORT, PGDATABASE, PGUSER and PGPASSWORD values in
`test/.env`. Do not commit this file or expose database credentials in web code.

In Supabase Authentication:

1. Enable Google under Sign In / Providers and configure the Google OAuth client.
2. Google Cloud's authorized redirect URI is your Supabase project's
   `https://your-project.supabase.co/auth/v1/callback`.
3. Set Site URL to `http://localhost:8091` and allow these Redirect URLs:
   - `http://localhost:8090/auth/callback`
   - `http://127.0.0.1:8090/auth/callback`
   - `http://localhost:8091/auth/callback`
   - `http://127.0.0.1:8091/auth/callback`

Google's client secret belongs in the provider settings. The browser uses PKCE.
The existing Remember me option selects local storage or session-only storage.
Email/password uses Supabase as well; confirmation requirements follow your
Supabase settings. Password-reset UI is still a prototype and does not send mail.

Signing in for the first time creates a local role profile. Signup can choose
entrepreneur or owner. Administrators must be assigned in the local database by
a trusted operator; URL changes, form values and OAuth metadata cannot grant
administrator access or change an existing role.

## Start on your laptop

From `test/`:

```powershell
npm install
npm run start:app
```

Leave that terminal running. In a second terminal, from `fyp_jaspr_web/`:

```powershell
npm install --prefix tool
npm run build-auth --prefix tool
jaspr serve --port 8090
```

Open `http://localhost:8090/login`. For a production preview instead:

```powershell
npm run build-auth --prefix tool
jaspr build
python tool/serve_client_preview.py --port 8091
```

Open `http://localhost:8091/login` and choose Continue with Google. Use the same
hostname on departure and return: localhost and 127.0.0.1 have separate storage.
`web/index.html` contains the local API address in the `sitewise-api` meta tag.

## Repeat the property import

From the repository root (requires Python openpyxl):

```powershell
python test/scripts/prepare-property-workbook.py "C:/path/to/property_workbook.xlsx"
node test/scripts/import-properties.js
```

The prepared JSON is ignored by Git. Import is transactional and upserts by
canonical property ID. Repeating it updates the same records without duplicating
them; it does not delete unrelated records. Restart/reload the browser afterwards
because the catalogue is cached for the browser session.

## Files to change

| Concern | Location |
| --- | --- |
| Google/email session and browser API requests | `tool/auth_client.js` (bundled into ignored `web/auth_bundle.js`) |
| Dart/browser bridge | `lib/data/auth_service.dart`, `auth_browser.dart` |
| Protected routes and role redirects | `lib/app.dart` |
| Live catalogue / source-index ranking | `lib/data/api_property_repository.dart` |
| Repository wiring | `lib/data/app_locator.dart` |
| Backend token verification / catalogue endpoints | `../test/app-api.js` |
| Local API startup | `../test/app-server.js` |
| PostgreSQL tables | `../test/app-schema.sql` |
| Import tools | `../test/scripts/prepare-property-workbook.py`, `import-properties.js` |

## Current scope

Properties, image URLs and sign-in are integrated. The imported catalogue is
read-only. New owner listings, uploads, persistent favourites/preferences, tour
storage, admin workflows and analysis models still need their corresponding
backend endpoints. Saved/compare choices currently last only for this browser
session. User role URLs are protected; the API independently validates tokens.

## Verification

```powershell
# From test/
npm run test:app
# From fyp_jaspr_web/
dart analyze lib
dart test
jaspr build
node tool/verify_backend_integration.js http://localhost:8091
```

Browser tests verify unsigned redirects and Google PKCE request parameters. Their
signed-in data-binding checks use explicitly labelled fixtures from the imported
workbook; they do not log in to a real Google account. Complete your own first
Google sign-in to verify the live consent, callback and authenticated session.

Production hosting needs SPA fallback for nested application routes. The local
preview and `web/_redirects` provide that behavior for supported hosts. The
current HTML base path assumes hosting at the domain root.
