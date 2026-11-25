# Git credentials

## Local configuration

FastAPI reads process environment variables and `backend/.env` and
`backend/.env.local` through Pydantic Settings. Start with
`backend/.env.example` when setting up a checkout. Supply both database URLs.
Use `.env.local` for per-checkout overrides. Keep Supabase server keys,
database passwords, and paid API keys in the backend
environment. The separate Express test service uses `test/.env.example`.

Flutter bundles `fyp_mobile_app/assets/config/sitewise_dev.json`. On a new
checkout, copy `sitewise_dev.example.json` to that filename and fill in the
public settings. Use a Supabase publishable key and public Google OAuth client
IDs. The JSON is distributed in the app, so keep server credentials out of it.
The existing mobile `config/sitewise_dev.env` can still be used for public
Dart defines.

Jaspr generates its browser assets with `npm run gen-auth-config` and
`npm run gen-map-config` from `fyp_jaspr_web/tool`. The generators accept
process environment variables or read the matching public values from
`backend/.env`. The generated browser assets are ignored by Git. Use the
browser-scoped CARTO basemap key for the map generator.

## Commit guard

Install Gitleaks 8.30 or newer and run
`git config --local core.hooksPath .githooks` in each new clone. The hook scans
the staged diff and prints only a generic failure message. On Windows it also
accepts a Gitleaks executable named `gitleaks.exe` in the Git common directory.

To inspect a blocked commit without displaying matching text or secret values,
run the following from the repository root in PowerShell.

```powershell
$report = [IO.Path]::GetTempFileName()
try {
    $scanner = Get-Command gitleaks -ErrorAction SilentlyContinue
    $exe = if ($scanner) { $scanner.Source } else {
        Join-Path (git rev-parse --git-common-dir) 'gitleaks.exe'
    }
    & $exe git --staged --redact=100 --no-banner --report-format json --report-path $report *> $null
    if ((Get-Item $report).Length) {
        Get-Content -Raw $report | ConvertFrom-Json | Select-Object RuleID, File, StartLine
    }
} finally {
    Remove-Item -LiteralPath $report
}
```

## History cleanup

The staged deletions preserve the local files. Older commits on remote-tracking
branches still contain private configuration, database backups and encryption
keys. Rotate live exposed credentials at their providers, then update local and
deployment configuration. Handle the historical payload encryption keys
according to storage retention and re-encryption needs.

After the owner authorizes a rewrite, inventory the current remote refs and
work in a fresh mirror. Use `git filter-repo --sensitive-data-removal` with
`--invert-paths --paths-from-file` and the candidate paths in
`git-history-private-paths.txt`. Prepare a private `--replace-text` file outside
the checkout for confirmed literals in source files that must be retained.
Start that inventory with the retired settings defaults, Alembic config,
Postgres helper scripts and `N01_EVIDENCE/TRACE_QUERIES.md`. Check historical
aliases and copies before freezing the plan. Scan the
rewritten refs before seeking separate authorization to update GitHub refs.
Coordinate the cleanup with collaborators so older clones cannot reintroduce
the removed objects.

[GitHub guidance on removing sensitive data](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
