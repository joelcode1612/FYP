# Sitewise FYP — Dart pub workspace

One pub workspace holding three packages: the Flutter **mobile-only** app, the
Jaspr **web** app (the entire web tree), and the framework-free shared package.

```
FYP/                          ← workspace root (pubspec.yaml: workspace: [...])
├── fyp_mobile_app/           Flutter app — mobile only (package: fyp)
├── fyp_jaspr_web/            Jaspr static web app (package: sitewise_jaspr_web)
├── shared_logic/             Pure-Dart shared package (bloc only, no Flutter/Jaspr)
└── test/                     Node test-map server (unrelated to the Dart packages)
```

## Architecture

- **`shared_logic`** — domain entities, use cases, pure-Dart repository
  implementations, application services (property, tour, recommendation,
  verification, auth) and the four shared cubits (`AppCubit`,
  `EntrepreneurCubit`, `OwnerCubit`, `AdminCubit`). May only depend on
  `bloc`/`meta` etc.; never on Flutter or Jaspr. Platform-bound sources
  (path_provider stores, OpenCV stitcher, camera/AR capture) stay in the
  mobile app.
- **`fyp_mobile_app`** — mobile UI, routing (`core/routing/app_routes.dart`),
  DI composition root (`application/services/service_locator.dart`), platform
  data sources. The Flutter **web tree has been removed** — the web app is
  Jaspr now. The app boots to onboarding/auth regardless of viewport width.
- **`fyp_jaspr_web`** — the whole web experience in Jaspr (static mode,
  port 8090): marketing landing, `/login` role picker, and all 24
  role pages (admin/owner/entrepreneur) with `?id=` detail routes, sharing the
  same `shared_logic` services/cubits through its own composition root
  (`lib/data/app_locator.dart`).

## Commands (run from the workspace root)

```sh
flutter pub get                    # resolves the whole workspace (one lockfile)
flutter analyze                    # analyzes every member, no issues expected
flutter test fyp_mobile_app        # mobile app tests (27)

cd shared_logic
dart analyze
dart test                          # shared cubit tests (18)
cd ..

cd fyp_jaspr_web
dart analyze
dart run tool/typecheck.dart       # compile-based typecheck harness (exit 0)
dart run jaspr_cli:jaspr build     # static build → build/jaspr (28 routes)
.\serve                            # dev server → http://localhost:8090
cd ..
```

**Start the dev server with `.\serve`, not `dart run jaspr_cli:jaspr serve`.**

`serve.cmd` frees port 8090 first, then starts the server. This matters because
**Windows does not terminate child processes when a console closes** — unlike
POSIX, where the shell sends `SIGHUP` to the process group. Closing the terminal
therefore leaves `jaspr serve` running and holding 8090 indefinitely. The next
`jaspr serve` then fails with `errno 10048 (EADDRINUSE)` while the *old* server
keeps serving *old* built assets, which looks exactly like "my changes had no
effect".

`serve.cmd` detects whatever owns the port, walks its Dart-only parent chain,
and kills it child-first before starting. It refuses to touch a non-Dart process.
A `.cmd` wrapper is used rather than a bare `.ps1` because this machine's
`LocalMachine` execution policy is `AllSigned`, which blocks unsigned scripts.

```
.\serve              start (clears the port first)
.\serve -CheckOnly   clear the port and exit without starting
.\serve -NoKill      report what holds the port, change nothing
.\serve -Port 8091   use a different port for this run
```


Deps between members use `shared_logic: any` (workspace resolution, no paths).
